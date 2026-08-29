// Storage benchmark worker: capability probe + paced/blast runs for raw OPFS
// (sync access handle) and IndexedDB. Driven by lib/benchmark/ over
// postMessage; one request at a time (the Dart side serializes). An aborted
// or failed run reports and stops — partial numbers would be fiction.
'use strict';

// in : {cmd:'probe'}
//      {cmd:'run', spec:{kind, workload:{packetBytes,packetsPerSec},
//        warmupSec, steadySec, ...kind-specific fields...}}
//      {cmd:'abort'}
// out: {type:'probe', facts}
//      {type:'result', result}
//      {type:'progress', log}
//      {type:'aborted'}
//      {type:'error', message}

let aborted = false;

class AbortError extends Error {}

function post(m) {
  self.postMessage(m);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function checkAbort() {
  if (aborted) throw new AbortError();
}

self.addEventListener('message', (e) => {
  const msg = e.data;
  if (msg.cmd === 'abort') {
    aborted = true;
    return;
  }
  handle(msg).catch((err) => {
    if (err instanceof AbortError) post({ type: 'aborted' });
    else post({ type: 'error', message: String((err && err.stack) || err) });
  });
});

async function handle(msg) {
  aborted = false;
  switch (msg.cmd) {
    case 'probe':
      post({ type: 'probe', facts: await probe() });
      break;
    case 'run':
      post({ type: 'result', result: await run(msg.spec) });
      break;
    default:
      throw new Error(`unknown cmd: ${msg.cmd}`);
  }
}

// -- shared helpers --------------------------------------------------------

function stat(samples) {
  if (samples.length === 0) return { p50: 0, p99: 0, max: 0 };
  const s = [...samples].sort((a, b) => a - b);
  const at = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  return { p50: at(0.5), p99: at(0.99), max: s[s.length - 1] };
}

function makeFiller() {
  let seed = 0x9e3779b9;
  return (arr) => {
    const dv = new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
    for (let i = 0; i + 4 <= arr.length; i += 4) {
      seed = (Math.imul(seed, 1664525) + 1013904223) | 0;
      dv.setUint32(i, seed, true);
    }
  };
}

function batchBytesFor(workload, batchMs) {
  const wanted = (workload.packetBytes * workload.packetsPerSec * batchMs) / 1000;
  return (
    Math.max(
      workload.packetBytes,
      Math.ceil(wanted / workload.packetBytes) * workload.packetBytes,
    )
  );
}

// Deliver batches on a fixed cadence and serialize commits. Per-commit time
// is the headline number: for OPFS paced runs the flush shows up as the
// spike; for IDB it is the transaction-complete wait.
async function paced(spec, commit, label, backend) {
  const batchMs = spec.batchMs;
  const batchBytes = batchBytesFor(spec.workload, batchMs);
  const warmupMs = spec.warmupSec * 1000;
  const steadyMs = spec.steadySec * 1000;
  const durations = [];
  let steadyBytes = 0;
  let backlogBytes = 0;
  let maxBacklogBytes = 0;
  let maxDeadlineMissMs = 0;
  let chain = Promise.resolve();
  const filler = makeFiller();
  const t0 = performance.now();
  let next = t0 + batchMs;
  let lastProgress = 0;

  while (performance.now() - t0 < warmupMs + steadyMs) {
    checkAbort();
    const now = performance.now();
    if (now < next) {
      await sleep(Math.min(next - now, 20));
      continue;
    }
    maxDeadlineMissMs = Math.max(maxDeadlineMissMs, now - next);
    next += batchMs;
    const inSteady = now - t0 >= warmupMs;
    const data = new Uint8Array(batchBytes);
    filler(data);
    backlogBytes += batchBytes;
    maxBacklogBytes = Math.max(maxBacklogBytes, backlogBytes);
    chain = chain.then(async () => {
      const t = performance.now();
      await commit(data);
      backlogBytes -= batchBytes;
      if (inSteady) {
        durations.push(performance.now() - t);
        steadyBytes += batchBytes;
      }
    });
    if (backlogBytes > 512 * 1024 * 1024) {
      throw new Error('backlog over 512MB — storage cannot keep up');
    }
    if (now - lastProgress > 2000) {
      lastProgress = now;
      post({
        type: 'progress',
        log: `${backend}/${label}: ${((now - t0) / 1000).toFixed(0)}s in, backlog ${(backlogBytes / 1e6).toFixed(1)}MB`,
      });
    }
  }
  await chain;

  const s = stat(durations);
  return {
    backend,
    mode: 'paced',
    label,
    targetBps: spec.workload.packetBytes * spec.workload.packetsPerSec,
    achievedBps: steadyBytes / (steadyMs / 1000),
    commits: durations.length,
    p50Ms: s.p50,
    p99Ms: s.p99,
    maxMs: s.max,
    durableBytes: steadyBytes,
    note: `maxBacklog ${(maxBacklogBytes / 1e6).toFixed(1)}MB; maxDeadlineMiss ${maxDeadlineMissMs.toFixed(1)}ms`,
  };
}

// Unthrottled: as fast as the backend drains, with a bounded in-flight window.
async function blast(spec, launch, label, backend) {
  const chunkBytes = spec.chunkBytes;
  const depth = spec.depth || 1;
  const warmupMs = spec.warmupSec * 1000;
  const steadyMs = spec.steadySec * 1000;
  const durations = [];
  let steadyBytes = 0;
  const filler = makeFiller();
  const buf = new Uint8Array(chunkBytes);
  filler(buf);
  const pending = new Set();
  let failure = null;
  const t0 = performance.now();

  while (performance.now() - t0 < warmupMs + steadyMs) {
    checkAbort();
    while (pending.size >= depth) {
      await Promise.race(pending);
      if (failure) throw failure;
    }
    const inSteady = performance.now() - t0 >= warmupMs;
    const t = performance.now();
    let signal;
    const done = new Promise((r) => (signal = r));
    pending.add(done);
    launch(buf)
      .then(
        () => {
          if (inSteady) {
            durations.push(performance.now() - t);
            steadyBytes += chunkBytes;
          }
        },
        (e) => {
          failure = failure || e;
        },
      )
      .finally(() => {
        pending.delete(done);
        signal();
      });
  }
  await Promise.all([...pending]);
  if (failure) throw failure;

  const s = stat(durations);
  return {
    backend,
    mode: 'blast',
    label,
    targetBps: 0,
    achievedBps: steadyBytes / (steadyMs / 1000),
    commits: durations.length,
    p50Ms: s.p50,
    p99Ms: s.p99,
    maxMs: s.max,
    durableBytes: steadyBytes,
    note: `depth ${depth}; chunk ${(chunkBytes / 1e6).toFixed(1)}MB`,
  };
}

// -- probe -----------------------------------------------------------------

async function probe() {
  const facts = {
    userAgent: navigator.userAgent,
    cores: navigator.hardwareConcurrency,
    crossOriginIsolated: self.crossOriginIsolated === true,
  };
  facts.opfsAvailable =
    !!(navigator.storage && typeof navigator.storage.getDirectory === 'function');
  facts.syncAccessHandle = await probeSyncAccessHandle();
  facts.idb = await probeIdb();
  if (navigator.storage) {
    try {
      const est = await navigator.storage.estimate();
      facts.storage = {
        usage: est.usage ?? null,
        quota: est.quota ?? null,
        persisted:
          typeof navigator.storage.persisted === 'function'
            ? await navigator.storage.persisted()
            : null,
      };
    } catch (e) {
      facts.storage = { error: String(e) };
    }
  } else {
    facts.storage = { error: 'navigator.storage missing' };
  }
  return facts;
}

async function probeSyncAccessHandle() {
  if (!(navigator.storage && typeof navigator.storage.getDirectory === 'function')) {
    return { ok: false, reason: 'navigator.storage.getDirectory missing' };
  }
  const name = 'bench_probe_sync.bin';
  try {
    const root = await navigator.storage.getDirectory();
    const fh = await root.getFileHandle(name, { create: true });
    const handle = await fh.createSyncAccessHandle();
    const buf = new Uint8Array(32 * 1024);
    makeFiller()(buf);
    const writes = [];
    const flushes = [];
    let off = 0;
    for (let i = 0; i < 40; i++) {
      let t = performance.now();
      handle.write(buf, { at: off });
      writes.push(performance.now() - t);
      if (i % 2 === 0) {
        t = performance.now();
        handle.flush();
        flushes.push(performance.now() - t);
      }
      off += buf.length;
    }
    const back = new Uint8Array(4);
    handle.read(back, { at: 0 });
    handle.close();
    await root.removeEntry(name);
    if (back[0] !== buf[0] || back[3] !== buf[3]) {
      return { ok: false, reason: 'read-back mismatch' };
    }
    return { ok: true, write32k: stat(writes), flush: stat(flushes) };
  } catch (e) {
    return { ok: false, reason: String(e) };
  }
}

async function probeIdb() {
  if (typeof indexedDB !== 'object' || !indexedDB) {
    return { ok: false, reason: 'indexedDB missing' };
  }
  const name = 'bench_probe_idb';
  try {
    const db = await new Promise((res, rej) => {
      const rq = indexedDB.open(name, 1);
      rq.onupgradeneeded = () => rq.result.createObjectStore('d');
      rq.onsuccess = () => res(rq.result);
      rq.onerror = () => rej(rq.error);
    });
    const buf = new Uint8Array(1024);
    makeFiller()(buf);
    const puts = [];
    let seq = 0;
    for (let i = 0; i < 40; i++) {
      const t = performance.now();
      await new Promise((res, rej) => {
        const tx = db.transaction('d', 'readwrite', { durability: 'relaxed' });
        tx.oncomplete = () => res();
        tx.onerror = () => rej(tx.error);
        tx.objectStore('d').put(buf, seq++);
      });
      puts.push(performance.now() - t);
    }
    db.close();
    indexedDB.deleteDatabase(name);
    return { ok: true, put1kRelaxed: stat(puts) };
  } catch (e) {
    return { ok: false, reason: String(e) };
  }
}

// -- runs ------------------------------------------------------------------

async function run(spec) {
  switch (spec.kind) {
    case 'opfs-paced':
      return runOpfsPaced(spec);
    case 'idb-paced':
      return runIdbPaced(spec);
    case 'opfs-blast':
      return runOpfsBlast(spec);
    case 'idb-blast':
      return runIdbBlast(spec);
    default:
      throw new Error(`unknown kind: ${spec.kind}`);
  }
}

async function runOpfsPaced(spec) {
  const root = await navigator.storage.getDirectory();
  const name = `bench_opfs_${Date.now()}.bin`;
  const fh = await root.getFileHandle(name, { create: true });
  const handle = await fh.createSyncAccessHandle();
  const label = `flush=${spec.flushMs}ms`;
  try {
    handle.truncate(0);
    let offset = 0;
    let lastFlush = performance.now();
    const result = await paced(
      spec,
      async (data) => {
        handle.write(data, { at: offset });
        offset += data.length;
        const now = performance.now();
        if (now - lastFlush >= spec.flushMs) {
          handle.flush();
          lastFlush = now;
        }
      },
      label,
      'opfs',
    );
    handle.flush();
    return result;
  } finally {
    handle.close();
    await root.removeEntry(name);
  }
}

async function runIdbPaced(spec) {
  const db = await openBenchIdb();
  const label = `batch=${spec.batchMs}ms ${spec.durability}`;
  let seq = 0;
  try {
    return await paced(
      spec,
      (data) =>
        new Promise((res, rej) => {
          const tx = db.transaction('d', 'readwrite', {
            durability: spec.durability,
          });
          tx.oncomplete = () => res();
          tx.onerror = () => rej(tx.error);
          tx.onabort = () => rej(tx.error);
          tx.objectStore('d').put(data, seq++);
        }),
      label,
      'idb',
    );
  } finally {
    await closeAndDeleteIdb(db);
  }
}

async function runOpfsBlast(spec) {
  const root = await navigator.storage.getDirectory();
  const name = `bench_opfs_blast_${Date.now()}.bin`;
  const fh = await root.getFileHandle(name, { create: true });
  const handle = await fh.createSyncAccessHandle();
  const label = `blast ${(spec.chunkBytes / 1e6).toFixed(1)}MB+flush`;
  try {
    handle.truncate(0);
    let offset = 0;
    const result = await blast(
      spec,
      async (buf) => {
        handle.write(buf, { at: offset });
        offset += buf.length;
        handle.flush();
      },
      label,
      'opfs',
    );
    return result;
  } finally {
    handle.close();
    await root.removeEntry(name);
  }
}

async function runIdbBlast(spec) {
  const db = await openBenchIdb();
  const label = `blast ${(spec.chunkBytes / 1e6).toFixed(1)}MB relaxed`;
  let seq = 0;
  try {
    return await blast(
      spec,
      (buf) =>
        new Promise((res, rej) => {
          const tx = db.transaction('d', 'readwrite', { durability: 'relaxed' });
          tx.oncomplete = () => res();
          tx.onerror = () => rej(tx.error);
          tx.onabort = () => rej(tx.error);
          tx.objectStore('d').put(buf, seq++);
        }),
      label,
      'idb',
    );
  } finally {
    await closeAndDeleteIdb(db);
  }
}

async function openBenchIdb() {
  const name = `bench_idb_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
  return new Promise((res, rej) => {
    const rq = indexedDB.open(name, 1);
    rq.onupgradeneeded = () => rq.result.createObjectStore('d');
    rq.onsuccess = () => res(rq.result);
    rq.onerror = () => rej(rq.error);
  });
}

function closeAndDeleteIdb(db) {
  const name = db.name;
  db.close();
  return new Promise((res) => {
    const rq = indexedDB.deleteDatabase(name);
    rq.onsuccess = rq.onerror = rq.onblocked = () => res();
  });
}
