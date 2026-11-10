import 'dart:math' as math;

import '../../models/display_unit.dart';
import '../../utils/nice_step.dart';

const double _kMinYTickPx = 32;
const _kClockRungs = [1, 2, 5, 10, 20, 30, 60];

/// Smallest clock-nice step >= [target] seconds.
double timeStepCeil(double target) {
  if (target < 1) return niceStepCeil(target);
  for (double scale = 1; ; scale *= 60) {
    for (final r in _kClockRungs) {
      final step = scale * r;
      if (step >= target) return step;
    }
  }
}

/// Format absolute seconds since session start as s, m:ss or h:mm:ss.
String formatAxisTick(double sec, int decimals) {
  if (sec < 0) return '-${formatAxisTick(-sec, decimals)}';
  final f = math.pow(10, decimals);
  final snapped = (sec * f).round() / f;
  final int m = snapped ~/ 60;
  final s = (snapped - m * 60).toStringAsFixed(decimals);
  if (m == 0) return s;
  final ss = s.padLeft(decimals == 0 ? 2 : decimals + 3, '0');
  if (m < 60) return '$m:$ss';
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:$ss';
}

typedef YAxisRange = ({
  double yMin,
  double yMax,
  double tickDelta,
  AxisRung rung,
  int decimals,
});

/// Snap a data range outward to a 1/2/5 tick grid in base display units.
/// Bounds and [tickDelta] stay unscaled so [rung] flips affect labels only,
/// never rescaling data or invalidating tiles.
YAxisRange computeYAxisRange(
  double dataMin,
  double dataMax,
  DisplayUnit unit,
  double plotHeight,
) {
  final lo = dataMin;
  final max = dataMax <= lo ? lo + 1.0 : dataMax;
  final tickDelta = niceStepCeil((max - lo) * _kMinYTickPx / plotHeight);
  final yMin = (lo / tickDelta).floor() * tickDelta;
  final yMax = (max / tickDelta).ceil() * tickDelta;
  final rung = unit.axisRung(math.max(yMin.abs(), yMax.abs()));
  final decimals = DisplayUnit.axisDecimalsFor(tickDelta / rung.factor);
  return (
    yMin: yMin,
    yMax: yMax,
    tickDelta: tickDelta,
    rung: rung,
    decimals: decimals,
  );
}

/// Major cadence for [step]: the next ladder rung at least five times larger.
int majorPeriod(double step, double Function(double target) stepCeil) {
  final superStep = stepCeil(5 * step);
  final period = (superStep / step).round();
  assert(
    (superStep - period * step).abs() < step * 1e-6,
    'superStep $superStep is not a multiple of step $step',
  );
  return period;
}

typedef AxisTick = ({double value, double pos, bool major});

/// Lazily enumerate the absolute k*step grid over the slacked window.
Iterable<AxisTick> axisTicks(
  double windowStart,
  double windowEnd, {
  required double step,
  required double Function(double target) stepCeil,
  required double enumSlack,
  required double Function(double value) posOf,
}) sync* {
  final period = majorPeriod(step, stepCeil);
  final lo = windowStart - enumSlack;
  final hi = windowEnd + enumSlack + step * 0.01;
  for (int k = (lo / step - 1e-9).ceil(); k * step <= hi; k++) {
    yield (value: k * step, pos: posOf(k * step), major: k % period == 0);
  }
}

/// Lazily enumerate half-step minor positions on the odd half-step grid.
Iterable<double> axisMinorTicks(
  double windowStart,
  double windowEnd, {
  required double step,
  required double enumSlack,
  required double Function(double value) posOf,
}) sync* {
  final minorStep = step / 2;
  final hi = windowEnd + enumSlack + step * 0.01;
  final firstMinor = ((windowStart - enumSlack) / minorStep - 1e-9).ceil();
  for (
    int j = firstMinor.isEven ? firstMinor + 1 : firstMinor;
    j * minorStep <= hi;
    j += 2
  ) {
    yield posOf(j * minorStep);
  }
}
