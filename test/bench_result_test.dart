import 'package:dynamite_app/benchmark/bench_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BenchResult.fromJson accepts all-double worker replies (dart2wasm '
      'dartify() produces doubles even for integral JS numbers)', () {
    final json = <String, Object?>{
      'backend': 'opfs',
      'mode': 'paced',
      'label': 'flush=100ms',
      'targetBps': 1536000.0,
      'achievedBps': 1536000.0,
      'commits': 250.0,
      'p50Ms': 0.1,
      'p99Ms': 0.5,
      'maxMs': 0.8,
      'durableBytes': 7680000.0,
      'note': 'maxBacklog 0.0MB',
    };

    final result = BenchResult.fromJson(json);

    expect(result.commits, 250);
    expect(result.durableBytes, 7680000);
    expect(result.achievedBps, 1536000.0);
  });

  test('batchBytesFor rounds up to whole packets', () {
    expect(
      batchBytesFor(Workload.upper, 20),
      480 * 64, // 30720B at 1.536MB/s over 20ms
    );
    expect(batchBytesFor(Workload.today, 20), 240);
    expect(batchBytesFor(Workload.today, 1000), 240 * 50);
  });
}
