import 'dart:async';

import 'package:web/web.dart' as web;

import '../services/database.dart';
import 'bench_spec.dart';
import 'bench_worker_client.dart';
import 'drift_bench.dart';

/// Sequencing and sweep policy for the benchmark tab: which specs run in
/// which order, where each executes (worker vs. in-process Drift), and the
/// single stream of log lines the UI renders.
class BenchController {
  BenchController({required AppDatabase db}) : _drift = DriftBenchRunner(db);

  final DriftBenchRunner _drift;
  final BenchWorkerClient _worker = BenchWorkerClient();

  final results = <BenchResult>[];
  final _lines = StreamController<String>.broadcast();
  Stream<String> get lines => _lines.stream;

  bool _running = false;
  bool get running => _running;
  bool _abortRequested = false;

  void _line(String line) => _lines.add(line);

  void abort() {
    _abortRequested = true;
    _worker.abort();
  }

  void dispose() => _worker.dispose();

  Future<void> probe() async {
    _line('== environment probe ==');
    _line('crossOriginIsolated (page): ${web.window.crossOriginIsolated}');
    final reply = await _worker.call({'cmd': 'probe'});
    final facts = (reply['facts'] as Map).cast<String, Object?>();
    _line('userAgent: ${facts['userAgent']}');
    _line(
      'cores: ${facts['cores']}  '
      'crossOriginIsolated (worker): ${facts['crossOriginIsolated']}  '
      'OPFS getDirectory: ${facts['opfsAvailable']}',
    );
    final sah = (facts['syncAccessHandle'] as Map).cast<String, Object?>();
    if (sah['ok'] == true) {
      _line(
        'OPFS sync access handle: OK — write 32KB ${_stat(sah['write32k'])}, '
        'flush ${_stat(sah['flush'])}',
      );
    } else {
      _line('OPFS sync access handle: FAILED — ${sah['reason']}');
    }
    final asyncW = facts['asyncWritable'];
    if (asyncW is Map) {
      final w = asyncW.cast<String, Object?>();
      if (w['ok'] == true) {
        _line(
          'OPFS async writable: OK — write 32KB ${_stat(w['write32k'])}, '
          'close ${(w['closeMs'] as num).toStringAsFixed(2)}ms',
        );
      } else {
        _line('OPFS async writable: FAILED — ${w['reason']}');
      }
    }
    final idb = (facts['idb'] as Map).cast<String, Object?>();
    if (idb['ok'] == true) {
      _line('IndexedDB: OK — put 1KB relaxed ${_stat(idb['put1kRelaxed'])}');
    } else {
      _line('IndexedDB: FAILED — ${idb['reason']}');
    }
    final storage = (facts['storage'] as Map).cast<String, Object?>();
    final error = storage['error'];
    if (error != null) {
      _line('storage estimate: FAILED — $error');
    } else {
      final usage = ((storage['usage'] as num?) ?? 0) / 1e6;
      final quota = ((storage['quota'] as num?) ?? 0) / 1e9;
      _line(
        'storage: usage ${usage.toStringAsFixed(1)}MB / '
        'quota ${quota.toStringAsFixed(2)}GB, '
        'persisted: ${storage['persisted']}',
      );
    }
    if (web.window.crossOriginIsolated != true) {
      _line(
        'NOTE: page is not cross-origin-isolated, so Drift may be on its '
        'degraded VFS fallback. Serve via tool/serve_web_isolated.ps1 '
        '(production-like) for honest Drift numbers.',
      );
    }
  }

  String _stat(Object? json) {
    final m = (json as Map).cast<String, Object?>();
    double v(String k) => (m[k] as num).toDouble();
    return 'p50 ${v('p50').toStringAsFixed(2)}ms '
        'p99 ${v('p99').toStringAsFixed(2)}ms '
        'max ${v('max').toStringAsFixed(2)}ms';
  }

  Future<void> runSweep({
    required Workload workload,
    required int steadySec,
    required Set<String> backends,
    required bool idbIncludeDefaultDurability,
    required bool includeBlast,
  }) async {
    if (_running) throw StateError('sweep already running');
    _running = true;
    _abortRequested = false;
    try {
      final specs = buildSweep(
        workload: workload,
        steadySec: steadySec,
        backends: backends,
        idbIncludeDefaultDurability: idbIncludeDefaultDurability,
        includeBlast: includeBlast,
      );
      _line(
        '== sweep: ${workload.bytesPerSec / 1e6}MB/s offered '
        '(${workload.packetsPerSec} x ${workload.packetBytes}B packets), '
        '$steadySec s steady per run, ${specs.length} runs ==',
      );
      _line(BenchResult.csvHeader);
      for (final spec in specs) {
        if (_abortRequested) break;
        await _runSpec(spec);
      }
      _line('== sweep done: ${results.length} result rows ==');
    } on BenchAborted {
      _line('-- aborted --');
    } finally {
      _running = false;
    }
  }

  Future<void> _runSpec(BenchSpec spec) async {
    _line('-- run ${spec.backend} ${spec.label} --');
    final BenchResult result;
    try {
      if (spec is DriftPacedSpec) {
        result = await _drift.runPaced(
          spec,
          aborted: () => _abortRequested,
          onProgress: _line,
        );
      } else if (spec is BlastSpec && spec.backend == 'drift') {
        result = await _drift.runBlast(
          spec,
          aborted: () => _abortRequested,
          onProgress: _line,
        );
      } else {
        result = await _runWorker(spec);
      }
    } on BenchAborted {
      _line('aborted during ${spec.backend} ${spec.label}');
      rethrow;
    } catch (e) {
      // A broken backend (e.g. old WebKit's sync-handle OPFS) fails its run
      // loudly but must not kill the sweep — the remaining backends' rows are
      // exactly the fallback data being collected.
      final detail = '$e'.replaceAll('\n', ' | ');
      _line('RUN FAILED ${spec.backend} ${spec.label}: $e');
      results.add(
        BenchResult(
          backend: spec.backend,
          mode: spec is BlastSpec ? 'blast' : 'paced',
          label: spec.label,
          targetBps: spec.workload.bytesPerSec.toDouble(),
          achievedBps: 0,
          commits: 0,
          p50Ms: 0,
          p99Ms: 0,
          maxMs: 0,
          durableBytes: 0,
          note: 'FAILED: $detail',
        ),
      );
      return;
    }
    results.add(result);
    _line(result.toCsv());
  }

  Future<BenchResult> _runWorker(BenchSpec spec) async {
    final reply = await _worker.call({
      'cmd': 'run',
      'spec': spec.toJson(),
    }, onEvent: (m) => _line('${m['log']}'));
    return BenchResult.fromJson(
      (reply['result'] as Map).cast<String, Object?>(),
    );
  }

  String resultsCsv() =>
      [BenchResult.csvHeader, for (final r in results) r.toCsv()].join('\n');
}
