import 'dart:math' as math;

/// Smallest value on the 1/2/5×10^k ladder at least [target]: round plot
/// bounds and axis steps at any scale. Total: non-positive or non-finite
/// input (a degenerate or broken fold window) falls back to a 1.0 step
/// instead of throwing in log()/pow() mid-paint.
double niceStepCeil(double target) {
  if (!target.isFinite || target <= 0) return 1.0;
  final base = math.pow(10, (math.log(target) / math.ln10).floor()).toDouble();
  if (base >= target) return base;
  if (2 * base >= target) return 2 * base;
  if (5 * base >= target) return 5 * base;
  return 10 * base;
}

/// Decimal digits that print a [niceStepCeil] result bare of trailing zeros:
/// integers with none, fractions with just enough ("0.02", "0.5" — never
/// "0.50").
int niceStepDecimals(double step) =>
    math.max(0, -((math.log(step) / math.ln10 + 1e-9).floor()));
