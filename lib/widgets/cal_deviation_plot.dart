import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The calibration "certificate plot": per-point deviations from the
/// end-point line, in µV/V — what the calibration corrects beyond gain and
/// offset. Pure presentation; the math lives in
/// `ChannelBoardCalibration.deviationsUvV`.
class CalDeviationPlot extends StatelessWidget {
  const CalDeviationPlot({super.key, required this.deviationsUvV});

  /// Deviation per cal point (storage order: +FS … −FS), in µV/V. The ±FS
  /// entries are 0 by construction.
  final List<double> deviationsUvV;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
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
    );
  }
}

class _DeviationPainter extends CustomPainter {
  _DeviationPainter(
    this.deviations, {
    required this.lineColor,
    required this.axisColor,
    required this.labelStyle,
  });

  final List<double> deviations;
  final Color lineColor;
  final Color axisColor;
  final TextStyle labelStyle;

  /// X labels in storage order — short forms of the tap-pair labels.
  static const _xLabels = ['+FS', '+mid', '0', '−mid', '−FS'];

  // Left gutter for the µV/V bound labels, bottom strip for the x labels.
  static const _leftPad = 64.0;
  static const _bottomPad = 16.0;
  static const _topPad = 6.0;
  static const _rightPad = 8.0;

  /// Smallest 1/2/5×10^k ≥ [v], so the y bound stays round at any scale.
  static double _niceBound(double v) {
    final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 5.0]) {
      if (mag * m >= v) return mag * m;
    }
    return mag * 10;
  }

  /// Nice bounds are 1/2/5×10^k: integers print bare, fractions with just
  /// enough decimals ("0.02", "0.5" — never "0.50").
  static String _fmtBound(double bound) {
    if (bound == bound.roundToDouble()) return bound.toInt().toString();
    final s = bound.toStringAsFixed(2);
    return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final maxAbs = deviations.fold<double>(0, (a, b) => math.max(a, b.abs()));
    // 20% headroom past the worst deviation; an exactly-linear device gets
    // an arbitrary ±0.01 µV/V frame so its flat zero line still reads as a
    // plot.
    final bound = maxAbs == 0 ? 0.01 : _niceBound(maxAbs * 1.2);

    const left = _leftPad;
    final right = size.width - _rightPad;
    const top = _topPad;
    final bottom = size.height - _bottomPad;
    final midY = (top + bottom) / 2;

    double xOf(int k) => left + k * (right - left) / (deviations.length - 1);
    double yOf(double uvV) => midY - (uvV / bound) * (midY - top);

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    // The ±bound frame, faint; the zero line at full axis strength.
    for (final uvV in [bound, 0.0, -bound]) {
      axisPaint.color = uvV == 0.0
          ? axisColor
          : axisColor.withValues(alpha: 0.4);
      canvas.drawLine(
        Offset(left, yOf(uvV)),
        Offset(right, yOf(uvV)),
        axisPaint,
      );
    }

    void label(String text, Offset centerLeft) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, centerLeft - Offset(0, tp.height / 2));
    }

    label('+${_fmtBound(bound)} µV/V', Offset(0, yOf(bound)));
    label('−${_fmtBound(bound)} µV/V', Offset(0, yOf(-bound)));

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final pointPaint = Paint()..color = lineColor;
    final path = Path()..moveTo(xOf(0), yOf(deviations[0]));
    for (int k = 1; k < deviations.length; ++k) {
      path.lineTo(xOf(k), yOf(deviations[k]));
    }
    canvas.drawPath(path, linePaint);
    for (int k = 0; k < deviations.length; ++k) {
      canvas.drawCircle(Offset(xOf(k), yOf(deviations[k])), 2.5, pointPaint);
      if (k < _xLabels.length) {
        final tp = TextPainter(
          text: TextSpan(text: _xLabels[k], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(xOf(k) - tp.width / 2, bottom + 3));
      }
    }

    // The one number on the plot (the rest live in the table): the extreme
    // deviation's value, placed off its point toward the zero line.
    var iExt = 0;
    for (int k = 1; k < deviations.length; ++k) {
      if (deviations[k].abs() > deviations[iExt].abs()) iExt = k;
    }
    final extreme = deviations[iExt];
    if (extreme != 0) {
      final tp = TextPainter(
        text: TextSpan(
          text:
              '${extreme > 0 ? '+' : ''}${extreme.toStringAsFixed(3)} µV/V',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final px = xOf(iExt);
      final py = yOf(extreme);
      final dx = (px - tp.width / 2).clamp(left, right - tp.width);
      final dy = extreme > 0 ? py + 6 : py - tp.height - 4;
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(_DeviationPainter old) =>
      old.deviations != deviations ||
      old.lineColor != lineColor ||
      old.axisColor != axisColor;
}
