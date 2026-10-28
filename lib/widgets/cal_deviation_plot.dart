import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../models/board_calibration.dart';
import '../utils/nice_step.dart';

/// The calibration "certificate plot": per-point end-point nonlinearity —
/// deviation from the chord through the ±FS cal points, in µV/V. Gain and
/// offset are removed by construction, so the plot shows shape only: what
/// the correction absorbs beyond the affine part. Display order is the
/// industry convention, −FS … +FS left-to-right; the input list is in
/// [kCalPointCount] storage order (+FS … −FS). Pure presentation; the math
/// lives in `CalibratedChannelBoard.deviationsUvV`.
class CalDeviationPlot extends StatelessWidget {
  const new({super.key, required this.deviationsUvV});

  /// Deviation per cal point (storage order: +FS … −FS), in µV/V. The ±FS
  /// entries are 0 by construction.
  final List<double> deviationsUvV;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final extreme = _extremeIndex(deviationsUvV);
    final label = extreme == null
        ? 'End-point nonlinearity plot, no measurable deviation'
        : 'End-point nonlinearity plot, maximum deviation '
              '${_fmtDeviation(deviationsUvV[extreme])} µV/V';
    return Semantics(
      image: true,
      label: label,
      child: SizedBox(
        height: 120,
        width: double.infinity,
        child: CustomPaint(
          painter: _DeviationPainter(
            deviationsUvV,
            lineColor: scheme.primary,
            axisColor: scheme.outlineVariant,
            labelStyle:
                theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ) ??
                TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// Index of the deviation with the largest magnitude, or null when every entry
/// is exactly zero. One scan serving both the semantics label and the on-plot
/// callout.
int? _extremeIndex(List<double> values) {
  int? best;
  for (int k = 0; k < values.length; ++k) {
    if (values[k] == 0) continue;
    if (best == null || values[k].abs() > values[best].abs()) best = k;
  }
  return best;
}

/// Signed, three decimals: "+0.125", "-0.040".
String _fmtDeviation(double uvV) =>
    '${uvV > 0 ? '+' : ''}${uvV.toStringAsFixed(3)}';

class _DeviationPainter extends CustomPainter {
  new(
    this.deviations, {
    required this.lineColor,
    required this.axisColor,
    required this.labelStyle,
  });

  /// Storage order (+FS … −FS); [paint] reverses for display.
  final List<double> deviations;
  final Color lineColor;
  final Color axisColor;
  final TextStyle labelStyle;

  /// X labels in display order (−FS … +FS) — short forms of the tap-pair
  /// labels.
  static const _xLabels = ['−FS', '−mid', '0', '+mid', '+FS'];

  // Left gutter for the µV/V bound labels, bottom strip for the x labels.
  static const _leftPad = 64.0;
  static const _bottomPad = 16.0;
  static const _topPad = 6.0;
  static const _rightPad = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Display convention is input increasing left-to-right; storage order
    // is +FS first.
    final values = deviations.reversed.toList(growable: false);
    assert(values.length == _xLabels.length, 'one x label per cal point');
    final maxAbs = values.fold<double>(0, (a, b) => math.max(a, b.abs()));
    // 20% headroom past the worst deviation; an exactly-affine device gets
    // an arbitrary ±0.01 µV/V frame so its flat zero line still reads as a
    // plot.
    final bound = maxAbs == 0 ? 0.01 : niceStepCeil(maxAbs * 1.2);
    final boundLabel = '${bound.toStringAsFixed(niceStepDecimals(bound))} µV/V';

    const left = _leftPad;
    final right = size.width - _rightPad;
    const top = _topPad;
    final bottom = size.height - _bottomPad;
    final midY = (top + bottom) / 2;

    double xOf(int k) => left + k * (right - left) / (values.length - 1);
    double yOf(double uvV) => midY - (uvV / bound) * (midY - top);

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, yOf(0)), Offset(right, yOf(0)), axisPaint);
    axisPaint.color = axisColor.withValues(alpha: 0.4);
    for (final uvV in [bound, -bound]) {
      canvas.drawLine(
        Offset(left, yOf(uvV)),
        Offset(right, yOf(uvV)),
        axisPaint,
      );
    }

    /// Paint [text] at the offset [at] derives from its laid-out size.
    void paintText(String text, Offset Function(double w, double h) at) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: .ltr,
      )..layout();
      tp.paint(canvas, at(tp.width, tp.height));
    }

    // Gutter labels hug the left edge, vertically centered on their bound.
    paintText('+$boundLabel', (_, h) => Offset(0, yOf(bound) - h / 2));
    paintText('−$boundLabel', (_, h) => Offset(0, yOf(-bound) - h / 2));

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final pointPaint = Paint()..color = lineColor;
    final path = Path()..moveTo(xOf(0), yOf(values[0]));
    for (int k = 1; k < values.length; ++k) {
      path.lineTo(xOf(k), yOf(values[k]));
    }
    canvas.drawPath(path, linePaint);
    for (int k = 0; k < values.length; ++k) {
      canvas.drawCircle(Offset(xOf(k), yOf(values[k])), 2.5, pointPaint);
      paintText(_xLabels[k], (w, _) => Offset(xOf(k) - w / 2, bottom + 3));
    }

    // The one number on the plot (the rest live in the table): the extreme
    // deviation's value, placed off its point toward the zero line.
    final iExt = _extremeIndex(values);
    if (iExt == null) return;
    final extreme = values[iExt];
    final py = yOf(extreme);
    paintText(
      '${_fmtDeviation(extreme)} µV/V',
      (w, h) => Offset(
        (xOf(iExt) - w / 2).clamp(left, right - w),
        extreme > 0 ? py + 6 : py - h - 4,
      ),
    );
  }

  @override
  bool shouldRepaint(_DeviationPainter old) => true;
}
