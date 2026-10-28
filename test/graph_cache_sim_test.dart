import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/widgets/graph_components.dart';

// Simulation harness for the segmented graph cache: drives
// [SegmentedGraphCache.paint] over seeded random window/config streams
// against synthetic signals (extrema entering and leaving folds), checking
// per frame:
//   1. every bake's sample range sits inside the fold window and at/below
//      the bake horizon -- the coverage invariants, checked independently
//      of the core's internal asserts;
//   2. every bake's RENDERED VALUES fit the frame's fold (the burn probe:
//      a bake covering samples the fold doesn't include raster-clips them
//      at the texture top -- the historical sawtooth bug -- and lying
//      values in a tile are the only frozen failure mode);
//   3. the sweep converges: once window and config go static, the cache
//      goes quiet within a bounded number of frames (no busy loops).
// Ops include targeted "peak exits the fold" moves (pan so a known
// extremum sits just outside an edge, then force a stale sweep) -- the
// exact burn geometry uniform random panning needs thousands of frames to
// find. A failure prints the seed and full op trace: a replay, not a
// mystery.

typedef _Call = ({int start, int end, int texW, bool gap});

class _Sim {
  new(this.seed) : rng = math.Random(seed * 7919 + 13) {
    // Deterministic spikes near tooth crests give folds that jump when the
    // window moves.
    spikes = {for (var k = 0; k < 8; k++) 100 + rng.nextInt(3900): 3.0};
    _growSignal(2000);
    // Fractional from the start (smooth-scroll lead), like production.
    viewStart = 3.0 + rng.nextDouble() * 3;
  }

  final int seed;
  final math.Random rng;
  final cache = SegmentedGraphCache();
  late final Map<int, double> spikes;

  static const double gw = 400;

  final List<double> signal = [];
  int totalSamples = 0;
  int? bakeable;

  double viewStart = 0;
  double viewSpan = 400;
  int generation = 0;
  double gh = 100;
  String remapKey = 'k';
  String destKey = 'u';

  final List<String> trace = [];
  final List<_Call> calls = [];

  /// Quadratic ramp cresting before an instant drop (the device demo's
  /// sawtooth shape), plus a slow sine and the seeded spikes.
  double _valueAt(int i) {
    final tooth = i % 800;
    double v = 50000 + 5000 * math.sin(i / 300);
    if (tooth < 600) {
      v += (tooth / 600) * (tooth / 600) * 200000; // crest ~250k
    }
    final spike = spikes[i];
    return spike == null ? v : v * spike;
  }

  void _growSignal(int toSamples) {
    while (totalSamples < toSamples) {
      signal.add(_valueAt(totalSamples));
      totalSamples++;
    }
  }

  int get _covStart => viewStart.floor();
  int get _covEnd => (viewStart + viewSpan).ceil();

  /// Window extremes, like the painters' fold; degenerate/empty -> 0..1.
  (double, double) _fold() {
    final from = math.max(0, _covStart);
    final to = math.min(_covEnd, totalSamples);
    double lo = double.infinity, hi = double.negativeInfinity;
    for (int i = from; i < to; i++) {
      lo = math.min(lo, signal[i]);
      hi = math.max(hi, signal[i]);
    }
    if (hi <= lo) return (0, 1);
    return (lo, hi);
  }

  double _clampStart(double v) =>
      v.clamp(0.0, math.max(0.0, totalSamples - 20)).toDouble();

  /// One random window/config op, logged to [trace]. Windows are often
  /// FRACTIONAL and occasionally tiny (the app's smooth-scroll lead makes
  /// every live frame fractional; a coverage-window off-by-one only shows
  /// as a 1-sample edge sliver, baked only when pps crosses the gap-bake
  /// threshold -- hence the tight zooms).
  void _randomOp() {
    final r = rng.nextDouble();
    if (r < 0.22) {
      viewStart = _clampStart(
        viewStart + rng.nextInt(161) - 80 + rng.nextDouble(),
      );
      trace.add('pan ${viewStart.toStringAsFixed(2)}');
    } else if (r < 0.34) {
      final f = [0.5, 0.7, 1.4, 2.0][rng.nextInt(4)];
      final center = viewStart + viewSpan / 2;
      viewSpan = (viewSpan * f).clamp(8.0, 3000.0);
      viewStart = _clampStart(center - viewSpan / 2);
      trace.add('zoom x$f -> span ${viewSpan.toStringAsFixed(2)}');
    } else if (r < 0.4) {
      // Tight zoom: pps up to 50 px/sample, past the gap-bake threshold.
      final center = viewStart + viewSpan / 2;
      viewSpan = [8.0, 12.0, 20.0][rng.nextInt(3)];
      viewStart = _clampStart(center - viewSpan / 2);
      trace.add('zoom-tight span $viewSpan');
    } else if (r < 0.55 && totalSamples > 60) {
      // Targeted straddle: push the window's own peak just outside an edge,
      // then (often) force a stale sweep so a straddling tile re-bakes.
      int peak = _covStart.clamp(0, totalSamples - 1);
      for (
        int i = math.max(0, _covStart);
        i < math.min(_covEnd, totalSamples);
        i++
      ) {
        if (signal[i] > signal[peak]) peak = i;
      }
      if (rng.nextBool()) {
        viewStart = _clampStart((peak + 1).toDouble());
        trace.add('exit-left peak@$peak');
      } else {
        viewStart = _clampStart(peak - viewSpan);
        trace.add('exit-right peak@$peak');
      }
      if (rng.nextDouble() < 0.7) {
        remapKey = 'k${rng.nextInt(1000000)}';
        trace.add('remap bump');
      }
    } else if (r < 0.68) {
      // Smooth-scroll creep: sub-sample motion with no config churn.
      viewStart = _clampStart(viewStart + rng.nextInt(4) * 0.25);
      trace.add('dwell creep ${viewStart.toStringAsFixed(2)}');
    } else if (r < 0.76) {
      gh = 100 + rng.nextInt(40).toDouble();
      trace.add('gh ${gh.round()}');
    } else if (r < 0.84) {
      remapKey = 'k${rng.nextInt(1000000)}';
      trace.add('remap bump');
    } else if (r < 0.88) {
      destKey = 'u${rng.nextInt(1000000)}';
      trace.add('destructive bump');
    } else if (r < 0.92) {
      bakeable = rng.nextBool()
          ? null
          : math.max(1, totalSamples - 1 - rng.nextInt(300));
      trace.add('bakeable $bakeable');
    } else if (r < 0.96 && totalSamples < 4000) {
      _growSignal(totalSamples + 500);
      trace.add('grow $totalSamples');
    } else if (r < 0.98) {
      viewStart = _clampStart(rng.nextDouble() * totalSamples);
      trace.add('jump ${viewStart.round()}');
    } else {
      generation++;
      trace.add('generation reset');
    }
  }

  static const _kEps = 1e-9;

  /// One painter-equivalent frame: fold the window, then paint. Every bake
  /// is checked against the coverage invariants and the fold bounds.
  bool frame() {
    final (foldLo, foldHi) = _fold();
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final workRemains = cache.paint(frameCanvas, (
      config: (
        generation: generation,
        destructiveKey: [destKey],
        remapKey: [remapKey],
        gw: gw,
        gh: gh,
        dpr: 1.0,
        viewStart: viewStart,
        viewSpan: viewSpan,
        yMin: foldLo,
        yMax: foldHi,
        totalSamples: totalSamples,
        bakeableSamples: bakeable ?? totalSamples,
        hPad: kSegmentImagePad,
        vPad: kSegmentImagePad,
      ),
      render: (Canvas canvas, int start, int end, int texW) {
        final isGap = identical(canvas, frameCanvas);
        calls.add((start: start, end: end, texW: texW, gap: isGap));
        if (!isGap) {
          // The value probe: extreme signal values this bake renders.
          double rLo = double.infinity, rHi = double.negativeInfinity;
          for (int i = start; i < math.min(end, totalSamples); i++) {
            rLo = math.min(rLo, signal[i]);
            rHi = math.max(rHi, signal[i]);
          }
          expect(
            start,
            greaterThanOrEqualTo(_covStart),
            reason: 'bake [$start, $end) starts before the fold window',
          );
          expect(
            end,
            lessThanOrEqualTo(_covEnd),
            reason: 'bake [$start, $end) ends past the fold window',
          );
          expect(
            end,
            lessThanOrEqualTo(bakeable ?? totalSamples),
            reason: 'bake [$start, $end) past the bake horizon',
          );
          expect(
            rHi,
            lessThanOrEqualTo(foldHi + _kEps),
            reason:
                'bake [$start, $end) renders $rHi above the fold '
                'max $foldHi (a burned tile)',
          );
          expect(
            rLo,
            greaterThanOrEqualTo(foldLo - _kEps),
            reason:
                'bake [$start, $end) renders $rLo below the fold '
                'min $foldLo (a burned tile)',
          );
        }
        return math.min((end - start) * gw / viewSpan, texW.toDouble());
      },
    ));
    recorder.endRecording().dispose();
    return workRemains;
  }

  /// Run [frames] random ops + frames. Returns a compact replay log.
  String run(int frames) {
    for (var f = 0; f < frames; f++) {
      _randomOp();
      trace.add('--- frame $f: ${frame() ? "bake" : "quiet"}');
    }
    return trace.join('\n');
  }

  /// Run no-op frames until the cache goes quiet; returns frames used, or
  /// [cap] if it never quieted.
  int settle({int cap = 60}) {
    for (var f = 0; f < cap; f++) {
      if (!frame()) {
        // Confirm the quiet frames repeat (no churn).
        if (!frame() && !frame()) return f;
      }
    }
    return cap;
  }
}

void main() {
  group('graph cache simulation', () {
    test('randomized streams keep bakes inside the fold window and fold '
        'bounds, then quiesce', () {
      for (var seed = 0; seed < 16; seed++) {
        final sim = _Sim(seed);
        try {
          sim.run(220);
          // Tail: with everything static the sweep must finish and stay
          // finished -- any busy loop trips here.
          expect(
            sim.settle(),
            lessThan(60),
            reason: 'seed $seed never quiesced after static frames',
          );
        } catch (_) {
          debugPrint('FAILING SEED $seed; op trace:\n${sim.trace.join('\n')}');
          rethrow;
        }
      }
    });

    test('deterministic replay: same seed, same bake/gap trace', () {
      // Not a cache property: it is what makes the "FAILING SEED n" log a
      // replay, so a sim failure is reproducible from its printed trace.
      String traceOf(_Sim sim) {
        final out = StringBuffer();
        for (var f = 0; f < 150; f++) {
          sim._randomOp();
          sim.frame();
          for (final c in sim.calls) {
            out.write('${c.start}-${c.end}-${c.texW}-${c.gap};');
          }
          out.write('|');
        }
        return out.toString();
      }

      expect(traceOf(_Sim(7)), traceOf(_Sim(7)));
    });

    test('config churn converges to quiescence once static', () {
      final sim = _Sim(3)
        ..viewStart = 800
        ..viewSpan = 400;
      for (var f = 0; f < 40; f++) {
        sim.gh = 100 + f.toDouble(); // remap staleness every frame
        sim.frame();
      }
      // gh is now static: the sweep finishes the remaining stale tiles
      // (3 screenfuls of tiles at most here) and then does nothing.
      expect(sim.settle(), lessThan(10));
    });

    test('slow zoom drift converges to quiescence once static', () {
      final sim = _Sim(4)
        ..viewStart = 800
        ..viewSpan = 400;
      for (var f = 0; f < 50; f++) {
        // 0.5%/frame x-drift: tiles cross the 8% threshold staggered, one
        // bake per ~16 frames each -- converging work, not a loop.
        sim.viewSpan += 2;
        sim.frame();
      }
      expect(sim.settle(), lessThan(10));
    });
  });
}
