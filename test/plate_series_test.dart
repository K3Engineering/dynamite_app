import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/plate_series.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/channel_converter.dart';
import 'package:dynamite_app/models/load_cell.dart';

void main() {
  group('PlateGeometry', () {
    test('bench CoP mm and footprint ratio', () {
      expect(benchPlate.copXmm(1), 222.25);
      expect(benchPlate.copYmm(-1), -304.8);
      expect(benchPlate.footprintHalfWidthNorm, closeTo(114.3 / 222.25, 1e-12));
      expect(benchPlate.footprintHalfLengthNorm, closeTo(330.2 / 304.8, 1e-12));
    });
  });

  group('PlateReader.fromCornerForce', () {
    test('total, sides and CoP from known corner loads', () {
      // TL=10, TR=20, BL=30, BR=40 -> total 100, left 40, right 60.
      final reader = PlateReader.fromCornerForce(
        (corner, index) => const [10.0, 20.0, 30.0, 40.0][corner],
        sampleRate: 1000,
      );
      final w = reader.weightsAt(0);
      expect(w.total, 100);
      expect(w.cop, (0.2, -0.4));
      final window = PlateWindow.capture(reader, 0, 3);
      expect(window.forceAt(1), 100);
      expect(window.leftAt(0), 40);
      expect(window.rightAt(0), 60);
      expect(window.copAt(2), (0.2, -0.4));
    });

    test('load on one back-right corner sits there', () {
      final reader = PlateReader.fromCornerForce(
        (corner, index) => corner == 3 ? 50.0 : 0.0,
        sampleRate: 1000,
      );
      final window = PlateWindow.capture(reader, 0, 1);
      expect(window.leftAt(0), 0);
      expect(window.rightAt(0), 50);
      expect(window.copAt(0), (1.0, -1.0));
    });
  });

  group('PlateReader.forConverters', () {
    const nominals = ChannelNominals(
      adcFsrV: 1.2,
      afeGain: 101,
      pgaGain: 1,
      excitationV: 4.53,
    );
    const cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
    const board = NominalChannelBoard(nominals);

    test('binds a raw stream to kgf', () {
      final converters = [
        for (int i = 0; i < 4; i++)
          const ChannelConverter(
            ChannelCalibration(board: board, loadCell: cell),
            null,
          ),
      ];
      final reader = PlateReader.forConverters(
        converters: converters,
        rawAt: (ch, i) => 1000,
        sampleRate: 1000,
      );
      final expected = cell.kgfPerMvV * 1000 / nominals.countsPerMvV;
      expect(reader.weightsAt(0).tl, closeTo(expected, 1e-9));
    });

    test('throws when a corner cannot express kgf', () {
      final converters = [
        for (int i = 0; i < 4; i++)
          ChannelConverter(
            ChannelCalibration(board: i == 1 ? null : board, loadCell: cell),
            null,
          ),
      ];
      expect(
        () => PlateReader.forConverters(
          converters: converters,
          rawAt: (ch, i) => 0,
          sampleRate: 1000,
        ),
        throwsStateError,
      );
    });
  });
}
