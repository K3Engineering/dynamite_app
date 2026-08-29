import '../services/database.dart';
import 'bench_spec.dart';

/// Non-web stand-in for the benchmark controller. The Bench tab itself
/// refuses to run off-web; this exists so the tab (and the app) compiles on
/// native targets where dart:js_interop / package:web are unavailable.
class BenchController {
  BenchController({required AppDatabase db});

  final List<BenchResult> results = [];
  Stream<String> get lines => const Stream.empty();
  bool get running => false;

  Future<void> probe() => throw UnsupportedError('web only');
  Future<void> runSweep({
    required Workload workload,
    required int steadySec,
    required Set<String> backends,
    required bool idbIncludeDefaultDurability,
    required bool includeBlast,
  }) => throw UnsupportedError('web only');

  void abort() {}
  void dispose() {}

  String resultsCsv() => BenchResult.csvHeader;
}
