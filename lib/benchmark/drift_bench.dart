import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../services/database.dart';
import 'bench_spec.dart';

/// Drift control backend: the production stack end-to-end — same AppDatabase,
/// same write APIs the live writer uses (createSessionWithFirstChunk, then
/// appendChunkAndGaps per flush), so its numbers are "what we have today",
/// not an idealized SQL pipeline.
class DriftBenchRunner {
  DriftBenchRunner(this._db);

  final AppDatabase _db;

  static const SessionHeader _header = (
    name: 'bench',
    sampleRate: 64000,
    channelCount: 8,
    channelLabels: '[]',
    tares: '[]',
    calibrationJson: '[]',
    visibleChannels: '[true]',
    displayUnit: 'raw',
    deviceInfoJson: '{}',
    boardMetaJson: null,
    recordedAt: 'bench',
  );

  Future<BenchResult> runPaced(
    DriftPacedSpec spec, {
    required bool Function() aborted,
    void Function(String)? onProgress,
  }) async {
    final batchBytes = batchBytesFor(spec.workload, spec.batchMs);
    return _withBenchSession((commit) async {
      final warmupMs = spec.warmupSec * 1000;
      final steadyMs = spec.steadySec * 1000;
      final durations = <double>[];
      var steadyBytes = 0;
      var backlogBytes = 0;
      var maxBacklogBytes = 0;
      var maxDeadlineMissMs = 0.0;
      var chain = Future<void>.value();
      final filler = _Filler();
      final sw = Stopwatch()..start();
      var nextMs = spec.batchMs.toDouble();
      var lastProgress = 0;

      while (sw.elapsedMilliseconds < warmupMs + steadyMs) {
        if (aborted()) throw const BenchAborted();
        final nowMs = sw.elapsedMicroseconds / 1000.0;
        if (nowMs < nextMs) {
          await Future<dynamic>.delayed(
            Duration(microseconds: ((nextMs - nowMs) * 1000).round()),
          );
          continue;
        }
        maxDeadlineMissMs = math.max(maxDeadlineMissMs, nowMs - nextMs);
        nextMs += spec.batchMs;
        final inSteady = nowMs >= warmupMs;
        final data = Uint8List(batchBytes);
        filler.fill(data);
        backlogBytes += batchBytes;
        maxBacklogBytes = math.max(maxBacklogBytes, backlogBytes);
        chain = chain.then((_) async {
          final commitSw = Stopwatch()..start();
          await commit(data);
          backlogBytes -= batchBytes;
          if (inSteady) {
            durations.add(commitSw.elapsedMicroseconds / 1000.0);
            steadyBytes += batchBytes;
          }
        });
        if (backlogBytes > 512 * 1024 * 1024) {
          throw StateError('drift backlog over 512MB — storage cannot keep up');
        }
        if (sw.elapsedMilliseconds - lastProgress > 2000) {
          lastProgress = sw.elapsedMilliseconds;
          onProgress?.call(
            'drift/batch=${spec.batchMs}ms: '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)}s in, '
            'backlog ${(backlogBytes / 1e6).toStringAsFixed(1)}MB',
          );
        }
      }
      await chain;

      final s = summarize(durations);
      return BenchResult(
        backend: 'drift',
        mode: 'paced',
        label: 'batch=${spec.batchMs}ms',
        targetBps: spec.workload.bytesPerSec.toDouble(),
        achievedBps: steadyBytes / (steadyMs / 1000),
        commits: durations.length,
        p50Ms: s.p50,
        p99Ms: s.p99,
        maxMs: s.max,
        durableBytes: steadyBytes,
        note:
            'maxBacklog ${(maxBacklogBytes / 1e6).toStringAsFixed(1)}MB; '
            'maxDeadlineMiss ${maxDeadlineMissMs.toStringAsFixed(1)}ms',
      );
    });
  }

  Future<BenchResult> runBlast(
    BlastSpec spec, {
    required bool Function() aborted,
    void Function(String)? onProgress,
  }) async {
    return _withBenchSession((commit) async {
      final chunkBytes = spec.chunkBytes;
      final warmupMs = spec.warmupSec * 1000;
      final steadyMs = spec.steadySec * 1000;
      final durations = <double>[];
      var steadyBytes = 0;
      var backlogBytes = 0;
      var chain = Future<void>.value();
      Completer<void>? capacity;
      final filler = _Filler();
      final buf = Uint8List(chunkBytes);
      filler.fill(buf);
      final sw = Stopwatch()..start();

      while (sw.elapsedMilliseconds < warmupMs + steadyMs) {
        if (aborted()) throw const BenchAborted();
        if (backlogBytes >= spec.depth * chunkBytes) {
          capacity ??= Completer<void>();
          await capacity!.future;
          continue;
        }
        final inSteady = sw.elapsedMilliseconds >= warmupMs;
        backlogBytes += chunkBytes;
        chain = chain.then((_) async {
          final commitSw = Stopwatch()..start();
          await commit(buf);
          backlogBytes -= chunkBytes;
          if (backlogBytes < spec.depth * chunkBytes) {
            capacity?.complete();
            capacity = null;
          }
          if (inSteady) {
            durations.add(commitSw.elapsedMicroseconds / 1000.0);
            steadyBytes += chunkBytes;
          }
        });
        // Let the drain actually start between enqueues.
        await Future<dynamic>.delayed(Duration.zero);
      }
      await chain;

      final s = summarize(durations);
      return BenchResult(
        backend: 'drift',
        mode: 'blast',
        label: 'blast ${(chunkBytes / 1e6).toStringAsFixed(1)}MB',
        targetBps: 0,
        achievedBps: steadyBytes / (steadyMs / 1000),
        commits: durations.length,
        p50Ms: s.p50,
        p99Ms: s.p99,
        maxMs: s.max,
        durableBytes: steadyBytes,
        note: 'depth ${spec.depth}',
      );
    });
  }

  /// Run [body] with a commit function that appends to a throwaway bench
  /// session (deleted afterwards, pass or fail).
  Future<T> _withBenchSession<T>(
    Future<T> Function(Future<void> Function(Uint8List data) commit) body,
  ) async {
    var sessionId = -1;
    var nextChunk = 0;
    Future<void> commit(Uint8List data) async {
      if (sessionId < 0) {
        sessionId = await _db.createSessionWithFirstChunk(
          header: _header,
          ssnOrigin: 0,
          gaps: '[]',
          data: data,
        );
        nextChunk = 1;
      } else {
        await _db.appendChunkAndGaps(sessionId, nextChunk++, data, '[]');
      }
    }

    try {
      return await body(commit);
    } finally {
      if (sessionId >= 0) await _db.deleteSession(sessionId);
    }
  }
}

/// Deterministic content without RNG overhead; also defeats any compression
/// a store might sneak in (same generator as the worker's, bit for bit).
class _Filler {
  int _seed = 0x9e3779b9;

  void fill(Uint8List out) {
    final view = ByteData.sublistView(out);
    for (var i = 0; i + 4 <= out.length; i += 4) {
      _seed = (_seed * 1664525 + 1013904223) & 0xffffffff;
      view.setUint32(i, _seed, Endian.little);
    }
  }
}
