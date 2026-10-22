import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/nice_step.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Golden table for the X-axis clock-step ladder (timeStepCeil /
/// majorPeriod / axisTicks), plus regressions for commit d035564's two
/// graph fixes: the label-cache pass-eviction semantics and the edge-tick
/// inclusion epsilon.
///
/// Seams used (both rename/extract-only; see graph_components.dart):
///  * [timeStepCeil] / [majorPeriod] / [formatAxisTick]: private helpers made
///    public with @visibleForTesting;
///  * [axisTicks]: the pure tick grid the painters' labels and majors come
///    from, extracted from _enumAxisLines so it needs no paragraph cache;
///  * [AxisLabelCache]: the renamed _LabelCache.
/// Grid positions are irrelevant to these tests: the tick grid is checked in
/// VALUE space, so the pixel mapping is the identity.
double identity(double value) => value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('axis tick golden table', () {
    // Mirrored from graph_components.dart: the 48 px minimum X tick spacing
    // (_kMinXTickPx, private) and the clock rungs (_kClockRungs, private).
    // Mirroring the CONSTANT (rename-only seam for the functions) keeps the
    // test honest: a changed constant changes step choices, and that SHOULD
    // be caught here rather than papered over by reading the private value.
    const kMinXTickPx = 48.0;
    const clockRungs = <int>[1, 2, 5, 10, 20, 30, 60];

    const sampleRates = <double>[50, 400];
    const spansSec = <double>[0.02, 0.5, 1, 2, 7.3, 30, 90, 480, 3600];
    const extentsPx = <double>[300, 800, 1400];

    /// Membership in the ladder timeStepCeil draws from: 1/2/5 decades below
    /// one second (the niceStepCeil ladder), then clock rungs of seconds,
    /// minutes, hours, ...
    bool onLadder(double step) {
      if (step < 1) {
        final exp = (math.log(step * (1 + 1e-12)) / math.ln10).floor();
        final r = step / math.pow(10, exp).toDouble();
        return [1.0, 2.0, 5.0].any((m) => (r - m).abs() < 1e-9);
      }
      for (double scale = 1; scale <= step * (1 + 1e-9); scale *= 60) {
        for (final c in clockRungs) {
          if ((step / scale - c).abs() < 1e-9) return true;
        }
      }
      return false;
    }

    /// Every ladder rung in [1e-4, 1e8] s (spans here never exceed 3600 s).
    Iterable<double> ladderRungs() sync* {
      for (int e = -4; e <= 0; e++) {
        final base = math.pow(10, e).toDouble();
        for (final m in [1.0, 2.0, 5.0]) {
          yield m * base;
        }
      }
      for (double scale = 1; scale <= 1e5; scale *= 60) {
        for (final c in clockRungs) {
          yield c * scale;
        }
      }
    }

    test('the smallest ladder rung covering the minimum spacing is used', () {
      for (final rate in sampleRates) {
        for (final span in spansSec) {
          for (final extent in extentsPx) {
            if (span * rate < 1) continue; // degenerate window
            final reason = 'span=${span}s extent=${extent}px rate=$rate';
            final target = span * kMinXTickPx / extent;
            final step = timeStepCeil(target);
            expect(step, greaterThanOrEqualTo(target), reason: reason);
            expect(onLadder(step), isTrue, reason: '$reason step=$step');
            // No smaller rung covers the target either: the choice is the
            // LADDER MINIMUM, not just any rung above it.
            for (final r in ladderRungs()) {
              if (r >= target * (1 - 1e-9)) {
                expect(
                  r,
                  greaterThanOrEqualTo(step * (1 - 1e-9)),
                  reason:
                      '$reason: rung $r covers the target '
                      '(>= $target) but is smaller than step $step',
                );
              }
            }
          }
        }
      }
    });

    test(
      'majors land exactly at k % majorPeriod == 0 on the absolute grid',
      () {
        for (final span in spansSec) {
          for (final extent in extentsPx) {
            final reason = 'span=${span}s extent=${extent}px';
            final step = timeStepCeil(span * kMinXTickPx / extent);
            final period = majorPeriod(step, timeStepCeil);
            // Doc contract: 5..10 steps per major, an exact ladder multiple.
            expect(period, inInclusiveRange(5, 10), reason: reason);
            final superStep = timeStepCeil(5 * step);
            expect(
              (period * step - superStep).abs(),
              lessThan(step * 1e-6),
              reason: '$reason: period * step must equal stepCeil(5 * step)',
            );

            final ticks = axisTicks(
              0,
              span,
              step: step,
              stepCeil: timeStepCeil,
              enumSlack: 0,
              posOf: identity,
            );
            expect(ticks, isNotEmpty, reason: reason);
            for (final t in ticks) {
              final k = (t.value / step).round();
              expect(k * step, closeTo(t.value, step * 1e-9), reason: reason);
              expect(t.major, k % period == 0, reason: '$reason k=$k');
            }
          }
        }
      },
    );

    test('consecutive tick labels never repeat for spans >= 1 s', () {
      // Mirror of _timeDecimals (private): enough fractional digits to
      // resolve the step, capped at 3 (ms).
      int decimals(double step) =>
          step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(1, 3);
      for (final span in spansSec.where((s) => s >= 1)) {
        for (final extent in extentsPx) {
          final reason = 'span=${span}s extent=${extent}px';
          final step = timeStepCeil(span * kMinXTickPx / extent);
          final dec = decimals(step);
          final ticks = axisTicks(
            0,
            span,
            step: step,
            stepCeil: timeStepCeil,
            enumSlack: 0,
            posOf: identity,
          );
          final labels = [for (final t in ticks) formatAxisTick(t.value, dec)];
          for (int i = 1; i < labels.length; i++) {
            expect(
              labels[i],
              isNot(labels[i - 1]),
              reason:
                  '$reason: labels ${labels[i - 1]} / ${labels[i]} '
                  '(step $step, $dec decimals)',
            );
          }
        }
      }
    });
  });

  group('edge-tick inclusion (d035564 epsilon)', () {
    test('a yMin snapped exactly onto a tick boundary keeps that tick', () {
      // The pre-fix drop, reached for real through _computeYRange-style
      // snapping (dataMin 0.7, plotHeight 100): tickDelta is 0.1 and
      // yMin = (0.7 / 0.1).floor() * 0.1 == 6 * 0.1, but
      // (yMin / step) == 6.000000000000001 in doubles, so .ceil() on it
      // starts the grid one tick high and drops the boundary tick. The
      // -1e-9 nudge keeps it.
      final ticks = axisTicks(
        6 * 0.1,
        9 * 0.1,
        step: 0.1,
        stepCeil: niceStepCeil,
        enumSlack: 0,
        posOf: identity,
      );
      expect(ticks, isNotEmpty);
      expect(ticks.first.value, closeTo(6 * 0.1, 1e-12));
    });

    test('inclusion holds at both boundaries for fractional steps', () {
      // Same fp shape at a 0.2 step: yMin = 6 * 0.1 is not on the 0.2 grid
      // in doubles ((6*0.1)/0.2 == 3.0000000000000004), yMax = 6 * 0.2 is.
      final ticks = axisTicks(
        6 * 0.1,
        6 * 0.2,
        step: 0.2,
        stepCeil: niceStepCeil,
        enumSlack: 0,
        posOf: identity,
      );
      expect(ticks.first.value, closeTo(6 * 0.1, 1e-12));
      expect(ticks.last.value, closeTo(6 * 0.2, 1e-12));
    });
  });

  group('AxisLabelCache pass eviction (d035564)', () {
    testWidgets(
      'overflow evicts only entries untouched in the current pass, and '
      'retired paragraphs survive until end of frame',
      (tester) async {
        final cache = AxisLabelCache();
        addTearDown(cache.dispose);
        const limit = 512; // the cache's internal _limit

        cache.beginPass();
        final early = cache.prepare('tick-0');
        Object? lastOfPass;
        for (int i = 1; i < limit + 88; i++) {
          final p = cache.prepare('tick-$i');
          lastOfPass = p;
          // Past the overflow point, metrics of THIS pass's paragraphs must
          // stay readable (pre-fix a whole-cache clear disposed paragraphs
          // the tick enumeration was still using -> "native peer has been
          // collected").
          expect(p.longestLine, greaterThan(0));
          expect(early.longestLine, greaterThan(0));
        }
        // Everything stamped in this pass is off-limits for eviction:
        // re-preparing returns the identical paragraph objects.
        expect(identical(cache.prepare('tick-0'), early), isTrue);
        expect(
          identical(cache.prepare('tick-${limit + 87}'), lastOfPass),
          isTrue,
        );
        // The whole pass outgrew the limit without evicting anything: no
        // end-of-frame drain to flush yet.
        await tester.pump();

        // Next pass, none of the old labels are touched: the first new
        // prepare trips the limit and evicts the entire stale set.
        cache.beginPass();
        cache.prepare('fresh-0');
        await tester.pump(); // runs the deferred disposal drain; must not throw

        // The stale entries really are gone: re-preparing an old key
        // produces a NEW paragraph instead of the kept instance.
        final rePrepped = cache.prepare('tick-0');
        expect(identical(rePrepped, early), isFalse);
        await tester.pump();
      },
    );
  });
}
