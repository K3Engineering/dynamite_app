// Session-file sink worker: the OPFS transport for the per-session file
// layout (<opfs>/sessions/<id>/{meta,data.raw,final}). Sync access handles
// are worker-only APIs, and flush() returning inside a write op IS the
// durability boundary — an ack means the bytes are durable. All semantics
// (journal format, recovery, damaged verdicts, id rules) live in the Dart
// store; this worker moves bytes and nothing else, so the only error model
// is "op threw" -> ok:false.
//
// Protocol: one request postMessage in, one ack out; the page serializes (one
// request in flight), so no op interleaving is possible here. Requests carry
// byte payloads as transferables (zero-copy); byte-returning ops use the
// ack's bytes channel the same way.
//
//   in : {seq, op, id?, intParam?, bytes?, bytes2?}
//   out: {seq, ok:true, result, bytes?} | {seq, ok:false, error}
'use strict';

const SESSIONS_DIR = 'sessions';
const JOURNAL_FILE = 'meta';
const DATA_FILE = 'data.raw';
const FINAL_FILE = 'final';

// id -> FileSystemSyncAccessHandle on data.raw. A handle exists exactly while
// its recording is live: created by createSession, released by closeSink (or
// delete). One recording at a time by app construction, but nothing here
// assumes that.
const openSinks = new Map();

const MSG_EVENT = 'message';

function isNotFound(e) {
  return e && e.name === 'NotFoundError';
}

async function sessionsRoot(create) {
  const root = await navigator.storage.getDirectory();
  try {
    return await root.getDirectoryHandle(SESSIONS_DIR, { create: !!create });
  } catch (e) {
    if (isNotFound(e)) return null;
    throw e;
  }
}

// The session directory for an existing session; null when absent. Ops that
// read "absent means empty" (reads, lengths, finalized checks) sit on top of
// this.
async function sessionDir(id) {
  const sessions = await sessionsRoot(false);
  if (!sessions) return null;
  try {
    return await sessions.getDirectoryHandle(id);
  } catch (e) {
    if (isNotFound(e)) return null;
    throw e;
  }
}

async function existingSessionDir(id) {
  const dir = await sessionDir(id);
  if (!dir) throw new Error(`no session directory ${id}`);
  return dir;
}

async function fileBytes(dir, name) {
  let fh;
  try {
    fh = await dir.getFileHandle(name);
  } catch (e) {
    if (isNotFound(e)) return null;
    throw e;
  }
  const file = await fh.getFile();
  return await file.arrayBuffer();
}

// Write bytes at EOF of `name` with its durability committed, holding the
// handle only for the op's duration. data.raw is the one file that instead
// stays open (openSinks) for a recording's lifetime.
async function appendFile(dir, name, bytes) {
  const fh = await dir.getFileHandle(name, { create: true });
  const handle = await fh.createSyncAccessHandle();
  try {
    handle.write(bytes, { at: handle.getSize() });
    handle.flush();
  } finally {
    handle.close();
  }
}

// -- ops -------------------------------------------------------------------

// Startup probe, run from here because a page-side probe proves nothing:
// sync handles are exactly the API the app depends on and exactly what old
// WebKit wedges on. Write/flush/read-back/verify, then remove the probe
// file. Any failure is an op error; the page fails the store's creation on
// it, so this browser can never pretend to record.
async function probe() {
  const root = await navigator.storage.getDirectory();
  const name = `sink_probe_${Date.now()}`;
  try {
    const fh = await root.getFileHandle(name, { create: true });
    const handle = await fh.createSyncAccessHandle();
    try {
      const out = new Uint8Array(1024);
      for (let i = 0; i < out.length; i++) out[i] = (i * 31 + 7) & 0xff;
      handle.write(out, { at: 0 });
      handle.flush();
      const back = new Uint8Array(out.length);
      handle.read(back, { at: 0 });
      for (let i = 0; i < out.length; i++) {
        if (back[i] !== out[i]) throw new Error('probe read-back mismatch');
      }
    } finally {
      handle.close();
    }
  } finally {
    try {
      await root.removeEntry(name);
    } catch (_) {}
  }
  return null;
}

// Remove the replaced SQLite store's files if an upgrade left them behind:
// pre-release dev data with no migration story. Best-effort per entry —
// litter is harmless.
async function dropLegacyDb() {
  const root = await navigator.storage.getDirectory();
  for await (const entry of root.values()) {
    if (!entry.name.startsWith('dynamite_sessions')) continue;
    try {
      await root.removeEntry(entry.name, { recursive: true });
    } catch (_) {}
  }
  return null;
}

// Create the session directory (which must NOT already exist — a collision
// is two recordings silently merged otherwise), its journal (msg.bytes as
// line 1) and data.raw (msg.bytes2) flushed, and keep data.raw's handle open
// as the recording's sink.
async function createSession(msg) {
  const sessions = await sessionsRoot(true);
  let exists = true;
  try {
    await sessions.getDirectoryHandle(msg.id);
  } catch (e) {
    if (isNotFound(e)) exists = false;
    else throw e;
  }
  if (exists) throw new Error(`session directory ${msg.id} already exists`);

  const dir = await sessions.getDirectoryHandle(msg.id, { create: true });
  const metaFh = await dir.getFileHandle(JOURNAL_FILE, { create: true });
  const meta = await metaFh.createSyncAccessHandle();
  try {
    meta.write(msg.bytes, { at: 0 });
    meta.flush();
  } finally {
    meta.close();
  }
  const dataFh = await dir.getFileHandle(DATA_FILE, { create: true });
  const data = await dataFh.createSyncAccessHandle();
  try {
    data.write(msg.bytes2, { at: 0 });
    data.flush();
  } catch (e) {
    data.close();
    throw e;
  }
  openSinks.set(msg.id, data);
  return null;
}

// One packet, appended at EOF and flushed; the ack carries the file length
// the finalize-time count check compares against.
function appendData(msg) {
  const handle = openSinks.get(msg.id);
  if (!handle) throw new Error(`append on a closed or unknown sink: ${msg.id}`);
  handle.write(msg.bytes, { at: handle.getSize() });
  handle.flush();
  return handle.getSize();
}

function closeSink(msg) {
  const handle = openSinks.get(msg.id);
  if (!handle) throw new Error(`close on a closed or unknown sink: ${msg.id}`);
  openSinks.delete(msg.id);
  handle.close();
  return null;
}

async function listDirIds() {
  const sessions = await sessionsRoot(false);
  if (!sessions) return [];
  const ids = [];
  for await (const entry of sessions.values()) {
    if (entry.kind === 'directory') ids.push(entry.name);
  }
  return ids;
}

async function readJournal(msg) {
  const dir = await sessionDir(msg.id);
  return dir ? await fileBytes(dir, JOURNAL_FILE) : null;
}

async function readData(msg) {
  const dir = await sessionDir(msg.id);
  return dir ? await fileBytes(dir, DATA_FILE) : null;
}

// A stat, not a read: the listing calls this per session on every refresh
// (including the recording tab's in-flight dir), so it must report the size
// without materializing bytes — and a live dir's exclusive sync handle
// comes from openSinks, since a second one would fail.
async function dataByteLength(msg) {
  const live = openSinks.get(msg.id);
  if (live) return live.getSize();
  const dir = await sessionDir(msg.id);
  if (!dir) return 0;
  let fh;
  try {
    fh = await dir.getFileHandle(DATA_FILE);
  } catch (e) {
    if (isNotFound(e)) return 0;
    throw e;
  }
  const handle = await fh.createSyncAccessHandle();
  try {
    return handle.getSize();
  } finally {
    handle.close();
  }
}

async function isFinalized(msg) {
  const dir = await sessionDir(msg.id);
  if (!dir) return false;
  try {
    await dir.getFileHandle(FINAL_FILE);
    return true;
  } catch (e) {
    if (isNotFound(e)) return false;
    throw e;
  }
}

// The completion marker: existence IS the bit, content never read — so an
// already-present marker is left exactly as it is.
async function touchFinal(msg) {
  const dir = await existingSessionDir(msg.id);
  await dir.getFileHandle(FINAL_FILE, { create: true });
  return null;
}

// The journal's one non-append mutation, driven only by the edit path's
// truncate-to-last-complete discipline.
async function truncateJournal(msg) {
  const dir = await existingSessionDir(msg.id);
  const fh = await dir.getFileHandle(JOURNAL_FILE);
  const handle = await fh.createSyncAccessHandle();
  try {
    handle.truncate(msg.intParam);
    handle.flush();
  } finally {
    handle.close();
  }
  return null;
}

async function appendJournal(msg) {
  const dir = await existingSessionDir(msg.id);
  await appendFile(dir, JOURNAL_FILE, msg.bytes);
  return null;
}

// The store's only destructive op, only ever a user gesture on the page
// side. A still-open sink goes first so no handle outlives its directory.
// Only bytes this layout can name are destroyed: the three known files are
// removed individually (absent ones skipped), then the now-empty directory
// — a non-recursive removeEntry throws when anything unexpected still sits
// in it, instead of destroying bytes the store never wrote.
async function deleteSession(msg) {
  const handle = openSinks.get(msg.id);
  if (handle) {
    openSinks.delete(msg.id);
    handle.close();
  }
  const dir = await sessionDir(msg.id);
  if (!dir) throw new Error(`no session directory ${msg.id}`);
  for (const name of [JOURNAL_FILE, DATA_FILE, FINAL_FILE]) {
    try {
      await dir.removeEntry(name);
    } catch (e) {
      if (!isNotFound(e)) throw e;
    }
  }
  const sessions = await sessionsRoot(false);
  await sessions.removeEntry(msg.id);
  return null;
}

// -- dispatch ---------------------------------------------------------------

const ops = {
  probe,
  dropLegacyDb,
  createSession,
  append: appendData,
  closeSink,
  listDirIds,
  readJournal,
  readData,
  dataByteLength,
  isFinalized,
  touchFinal,
  truncateJournal,
  appendJournal,
  delete: deleteSession,
};

// Ops whose return value goes out on the ack's byte channel (transferred)
// instead of the JSON result field; null means "file absent".
const BYTES_OPS = new Set(['readJournal', 'readData']);

self.addEventListener(MSG_EVENT, (e) => {
  const msg = e.data;
  Promise.resolve()
    .then(() => {
      const op = ops[msg.op];
      if (!op) throw new Error(`unknown op: ${msg.op}`);
      return op(msg);
    })
    .then((value) => {
      const ack = { seq: msg.seq, ok: true };
      if (BYTES_OPS.has(msg.op)) {
        ack.bytes = value;
        self.postMessage(ack, value ? [value] : []);
      } else {
        ack.result = value === undefined ? null : value;
        self.postMessage(ack, []);
      }
    })
    .catch((err) => {
      self.postMessage({
        seq: msg && msg.seq,
        ok: false,
        error: String((err && err.stack) || err),
      });
    });
});
