import 'dart:math' as math;

/// Thrown when the user (or the tab) cancels a run mid-flight.
class BenchAborted implements Exception {
  const BenchAborted();
  @override
  String toString() => 'benchmark aborted';
}

/// One offered workload: fixed-size packets on a fixed cadence, identical for
/// every backend so their numbers stay comparable.
class Workload {
  const Workload({required this.packetBytes, required this.packetsPerSec});

  /// Today's stream: 1 ksps x 4ch x 3B, in 20-sample packets 50x/s.
  static const today = Workload(packetBytes: 240, packetsPerSec: 50);

  /// Upper band: 64 ksps x 8ch x 3B at the same 20-sample packet shape.
  static const upper = Workload(packetBytes: 480, packetsPerSec: 3200);

  final int packetBytes;
  final int packetsPerSec;

  int get bytesPerSec => packetBytes * packetsPerSec;

  Map<String, Object?> toJson() => {
    'packetBytes': packetBytes,
    'packetsPerSec': packetsPerSec,
  };
}

/// Bytes per commit unit for a [batchMs] accumulation window, rounded up to
/// whole packets.
int batchBytesFor(Workload workload, int batchMs) {
  final wanted = workload.bytesPerSec * batchMs / 1000;
  return math.max(
    workload.packetBytes,
    (wanted / workload.packetBytes).ceil() * workload.packetBytes,
  );
}

/// One scheduled run. The web backends serialize to web/bench_worker.js; the
/// Drift variants execute in-process against the real AppDatabase.
sealed class BenchSpec {
  const BenchSpec({
    required this.workload,
    required this.warmupSec,
    required this.steadySec,
  });

  final Workload workload;
  final int warmupSec;
  final int steadySec;

  String get backend;
  String get kind;
  String get label;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'workload': workload.toJson(),
    'warmupSec': warmupSec,
    'steadySec': steadySec,
  };
}

/// OPFS sync-access-handle paced run: per-batch writes, flush every
/// [flushMs]. [batchMs] fixes the write-unit size independent of cadence.
final class OpfsPacedSpec extends BenchSpec {
  const OpfsPacedSpec({
    required super.workload,
    required super.warmupSec,
    required super.steadySec,
    required this.batchMs,
    required this.flushMs,
  });

  final int batchMs;
  final int flushMs;

  @override
  String get backend => 'opfs';
  @override
  String get kind => 'opfs-paced';
  @override
  String get label => 'flush=${flushMs}ms';

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'batchMs': batchMs,
    'flushMs': flushMs,
  };
}

/// IndexedDB paced run: one transaction (one put of the whole batch) every
/// [batchMs], with the given transaction durability hint.
final class IdbPacedSpec extends BenchSpec {
  const IdbPacedSpec({
    required super.workload,
    required super.warmupSec,
    required super.steadySec,
    required this.batchMs,
    required this.durability,
  });

  final int batchMs;
  final String durability;

  @override
  String get backend => 'idb';
  @override
  String get kind => 'idb-paced';
  @override
  String get label => 'batch=${batchMs}ms $durability';

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'batchMs': batchMs,
    'durability': durability,
  };
}

/// Drift control run: one appendChunkAndGaps transaction every [batchMs],
/// mirroring the live writer's flush loop.
final class DriftPacedSpec extends BenchSpec {
  const DriftPacedSpec({
    required super.workload,
    required super.warmupSec,
    required super.steadySec,
    required this.batchMs,
  });

  final int batchMs;

  @override
  String get backend => 'drift';
  @override
  String get kind => 'drift-paced';
  @override
  String get label => 'batch=${batchMs}ms';
}

/// Unthrottled ceiling run: fixed-size chunks as fast as the backend drains,
/// with [depth] commits in flight. [backend] is opfs | idb | drift.
final class BlastSpec extends BenchSpec {
  const BlastSpec({
    required this.backend,
    required super.workload,
    required super.warmupSec,
    required super.steadySec,
    required this.chunkBytes,
    required this.depth,
  });

  @override
  final String backend;
  final int chunkBytes;
  final int depth;

  @override
  String get kind => '$backend-blast';
  @override
  String get label => 'blast ${(chunkBytes / 1e6).toStringAsFixed(1)}MB';

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'chunkBytes': chunkBytes,
    'depth': depth,
  };
}

class BenchResult {
  const BenchResult({
    required this.backend,
    required this.mode,
    required this.label,
    required this.targetBps,
    required this.achievedBps,
    required this.commits,
    required this.p50Ms,
    required this.p99Ms,
    required this.maxMs,
    required this.durableBytes,
    required this.note,
  });

  factory BenchResult.fromJson(Map<String, Object?> j) => BenchResult(
    backend: j['backend'] as String,
    mode: j['mode'] as String,
    label: j['label'] as String,
    targetBps: (j['targetBps'] as num).toDouble(),
    achievedBps: (j['achievedBps'] as num).toDouble(),
    // dart2wasm's dartify() maps every JS number to double; dart2js/VM keep
    // integral values as int. Parse through num so both shapes work.
    commits: (j['commits'] as num).toInt(),
    p50Ms: (j['p50Ms'] as num).toDouble(),
    p99Ms: (j['p99Ms'] as num).toDouble(),
    maxMs: (j['maxMs'] as num).toDouble(),
    durableBytes: (j['durableBytes'] as num).toInt(),
    note: j['note'] as String,
  );

  final String backend;
  final String mode;
  final String label;
  final double targetBps;
  final double achievedBps;
  final int commits;
  final double p50Ms;
  final double p99Ms;
  final double maxMs;
  final int durableBytes;
  final String note;

  static const csvHeader =
      'backend,mode,label,targetMBs,achievedMBs,commits,p50ms,p99ms,maxms,durableMB,note';

  String toCsv() => [
    backend,
    mode,
    label,
    (targetBps / 1e6).toStringAsFixed(3),
    (achievedBps / 1e6).toStringAsFixed(3),
    '$commits',
    p50Ms.toStringAsFixed(2),
    p99Ms.toStringAsFixed(2),
    maxMs.toStringAsFixed(2),
    (durableBytes / 1e6).toStringAsFixed(1),
    '"$note"',
  ].join(',');
}

/// p50/p99/max of per-commit durations in milliseconds.
({double p50, double p99, double max}) summarize(List<double> samplesMs) {
  if (samplesMs.isEmpty) return (p50: 0, p99: 0, max: 0);
  final s = [...samplesMs]..sort();
  double at(double p) => s[math.min(s.length - 1, (p * s.length).floor())];
  return (p50: at(0.5), p99: at(0.99), max: s.last);
}

/// The full sweep table, in run order.
List<BenchSpec> buildSweep({
  required Workload workload,
  required int steadySec,
  required Set<String> backends,
  required bool idbIncludeDefaultDurability,
  required bool includeBlast,
}) {
  const warmupSec = 2;
  const opfsFlushSweep = [20, 50, 100, 250, 500, 1000, 2000];
  const batchSweep = [10, 50, 100, 250, 1000];
  const blastChunkBytes = 1024 * 1024;

  final specs = <BenchSpec>[];

  if (backends.contains('opfs')) {
    for (final flushMs in opfsFlushSweep) {
      specs.add(
        OpfsPacedSpec(
          workload: workload,
          warmupSec: warmupSec,
          steadySec: steadySec,
          batchMs: 20,
          flushMs: flushMs,
        ),
      );
    }
    if (includeBlast) {
      specs.add(
        BlastSpec(
          backend: 'opfs',
          workload: workload,
          warmupSec: 1,
          steadySec: 5,
          chunkBytes: blastChunkBytes,
          depth: 1,
        ),
      );
    }
  }
  if (backends.contains('idb')) {
    for (final batchMs in batchSweep) {
      specs.add(
        IdbPacedSpec(
          workload: workload,
          warmupSec: warmupSec,
          steadySec: steadySec,
          batchMs: batchMs,
          durability: 'relaxed',
        ),
      );
    }
    if (idbIncludeDefaultDurability) {
      for (final batchMs in batchSweep) {
        specs.add(
          IdbPacedSpec(
            workload: workload,
            warmupSec: warmupSec,
            steadySec: steadySec,
            batchMs: batchMs,
            durability: 'default',
          ),
        );
      }
    }
    if (includeBlast) {
      specs.add(
        BlastSpec(
          backend: 'idb',
          workload: workload,
          warmupSec: 1,
          steadySec: 5,
          chunkBytes: blastChunkBytes,
          depth: 8,
        ),
      );
    }
  }
  if (backends.contains('drift')) {
    for (final batchMs in batchSweep) {
      specs.add(
        DriftPacedSpec(
          workload: workload,
          warmupSec: warmupSec,
          steadySec: steadySec,
          batchMs: batchMs,
        ),
      );
    }
    if (includeBlast) {
      specs.add(
        BlastSpec(
          backend: 'drift',
          workload: workload,
          warmupSec: 1,
          steadySec: 5,
          chunkBytes: blastChunkBytes,
          depth: 1,
        ),
      );
    }
  }
  return specs;
}
