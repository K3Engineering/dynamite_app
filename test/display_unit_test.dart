import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/display_unit.dart';

/// Tests for [DisplayUnit]'s presentation behavior: the availability ladder
/// (per-unit availability vs the effective fallback), formatting, and the
/// SI-prefix axis helpers. Conversion itself is ChannelConverter's (see
/// channel_converter_test.dart).
void main() {
  group('effective', () {
    // The availability quadrants. (noBoard + cell) is meaningless — no
    // board constants resolve without a read — but the ladder must not care.
    const noBoard = (boardHasNominals: false, anyActiveHasLoadCell: false);
    const boardNoCell = (boardHasNominals: true, anyActiveHasLoadCell: false);
    const boardAndCell = (boardHasNominals: true, anyActiveHasLoadCell: true);

    test('no board constants is raw, for every preference', () {
      for (final u in DisplayUnit.values) {
        expect(u.effective(noBoard), DisplayUnit.raw, reason: u.symbol);
        expect(
          u.effective((boardHasNominals: false, anyActiveHasLoadCell: true)),
          DisplayUnit.raw,
          reason: u.symbol,
        );
      }
    });

    test('force with no active load cell becomes mV/V', () {
      for (final u in [
        DisplayUnit.kN,
        DisplayUnit.lbf,
        DisplayUnit.kgf,
        DisplayUnit.n,
      ]) {
        expect(u.effective(boardNoCell), DisplayUnit.mVv, reason: u.symbol);
      }
    });

    test('force with a load cell stays', () {
      expect(DisplayUnit.kN.effective(boardAndCell), DisplayUnit.kN);
    });

    test('electrical preferences are not promoted', () {
      expect(DisplayUnit.mVv.effective(boardNoCell), DisplayUnit.mVv);
      expect(DisplayUnit.mV.effective(boardNoCell), DisplayUnit.mV);
      expect(DisplayUnit.raw.effective(boardNoCell), DisplayUnit.raw);
      expect(DisplayUnit.raw.effective(boardAndCell), DisplayUnit.raw);
    });

    test('isAvailable matches the effective ladder', () {
      expect(DisplayUnit.raw.isAvailable(noBoard), isTrue);
      expect(DisplayUnit.mVv.isAvailable(noBoard), isFalse);
      expect(DisplayUnit.mVv.isAvailable(boardNoCell), isTrue);
      expect(DisplayUnit.kN.isAvailable(boardNoCell), isFalse);
      expect(DisplayUnit.kN.isAvailable(boardAndCell), isTrue);
    });
  });

  group('formatting', () {
    test('mV/V shows four decimals with an explicit sign', () {
      expect(DisplayUnit.mVv.format(1.996), '+1.9960 mV/V');
      expect(DisplayUnit.mVv.formatValueOnly(-0.5), '-0.5000');
      expect(DisplayUnit.raw.format(12345), '+12345 Raw');
      expect(DisplayUnit.kgf.format(1.5), '+1.500 kgf');
    });
  });

  group('axisRung', () {
    String sym(DisplayUnit u, double maxMag) => u.axisRung(maxMag).symbol;

    test('coarsest rung keeping scaled magnitudes >= 1', () {
      expect(sym(DisplayUnit.mV, 2), 'mV');
      expect(sym(DisplayUnit.mV, 0.4), 'µV'); // 400 µV
      expect(sym(DisplayUnit.mV, 4e-4), 'nV'); // 400 nV
      expect(sym(DisplayUnit.mVv, 0.02), 'µV/V');
      expect(sym(DisplayUnit.mVv, 2e-5), 'nV/V'); // 20 nV/V
      expect(sym(DisplayUnit.kgf, 2500), 'tf');
      expect(sym(DisplayUnit.kgf, 999), 'kgf');
      expect(sym(DisplayUnit.kgf, 0.5), 'gf'); // 500 gf
      expect(sym(DisplayUnit.n, 15000), 'kN');
      expect(sym(DisplayUnit.n, 5), 'N');
      expect(sym(DisplayUnit.n, 0.05), 'mN');
      expect(sym(DisplayUnit.kN, 2), 'kN');
      expect(sym(DisplayUnit.kN, 0.002), 'N'); // 2 N
      expect(sym(DisplayUnit.kN, 5e-4), 'mN'); // 500 mN
    });

    test('rung boundaries are inclusive at exactly 1', () {
      expect(sym(DisplayUnit.mV, 1), 'mV');
      expect(sym(DisplayUnit.mV, 1e-3), 'µV');
      expect(sym(DisplayUnit.kgf, 1000), 'tf');
      expect(sym(DisplayUnit.kgf, 1e-3), 'gf');
    });

    test('zero and sub-rung magnitudes clamp to the finest rung', () {
      expect(sym(DisplayUnit.mV, 0), 'nV');
      expect(sym(DisplayUnit.mV, 4e-7), 'nV'); // 0.4 nV
      expect(sym(DisplayUnit.kN, 4e-7), 'mN'); // 0.4 mN
    });

    test('single-rung units never scale', () {
      expect(sym(DisplayUnit.lbf, 0.031), 'lbf');
      expect(sym(DisplayUnit.lbf, 5000), 'lbf');
      expect(sym(DisplayUnit.raw, 0), 'Raw');
      expect(sym(DisplayUnit.raw, 8388608), 'Raw');
    });
  });

  group('axisDecimalsFor', () {
    test('resolves the 1/2/5 step exactly', () {
      expect(DisplayUnit.axisDecimalsFor(5), 0);
      expect(DisplayUnit.axisDecimalsFor(2), 0);
      expect(DisplayUnit.axisDecimalsFor(1000), 0);
      expect(DisplayUnit.axisDecimalsFor(0.5), 1);
      expect(DisplayUnit.axisDecimalsFor(0.2), 1);
      expect(DisplayUnit.axisDecimalsFor(0.05), 2);
      expect(DisplayUnit.axisDecimalsFor(0.02), 2);
      expect(DisplayUnit.axisDecimalsFor(0.001), 3);
      expect(DisplayUnit.axisDecimalsFor(5e-4), 4);
      expect(DisplayUnit.axisDecimalsFor(1e-7), 7);
    });

    test('is robust to floating-point noise near powers of ten', () {
      expect(DisplayUnit.axisDecimalsFor(1e3), 0);
      expect(DisplayUnit.axisDecimalsFor(1e-4 / 1e-6), 0); // ~100
      expect(DisplayUnit.axisDecimalsFor(1e-6 / 1e-3), 3); // ~0.001
    });
  });
}
