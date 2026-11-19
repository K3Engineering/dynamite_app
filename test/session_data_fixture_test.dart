import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_data.dart';
import 'package:dynamite_app/services/session_preparation.dart';

import 'helpers/session_data_fixture.dart';

void main() {
  SessionData buildFixture({
    List<Int32List>? channels,
    int sampleRate = 1000,
    List<double?> tares = const [null],
    GapList? gaps,
  }) => sessionDataFixture(
    channels:
        channels ??
        [
          Int32List.fromList([1, 2, 3]),
        ],
    sampleRate: sampleRate,
    calibrations: const [ChannelCalibration(board: null)],
    tares: tares,
    gaps: gaps,
  );

  test('rejects empty and ragged channel arrays', () {
    expect(() => buildFixture(channels: []), throwsArgumentError);
    expect(
      () => buildFixture(
        channels: [
          Int32List.fromList([1, 2]),
          Int32List.fromList([1]),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('rejects out-of-bounds gaps without clamping them', () {
    expect(
      () => buildFixture(gaps: GapList()..append(3, 4)),
      throwsA(
        isA<RangeError>().having(
          (error) => error.message,
          'message',
          contains('gap range'),
        ),
      ),
    );
  });

  test('rejects an invalid sample rate or tare count', () {
    expect(() => buildFixture(sampleRate: 0), throwsArgumentError);
    expect(() => buildFixture(tares: const []), throwsArgumentError);
    for (final tare in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => buildFixture(tares: [tare]), throwsArgumentError);
    }
  });

  test('rejects gap samples that do not hold the preceding value', () {
    expect(
      () => buildFixture(
        channels: [
          Int32List.fromList([10, 20]),
        ],
        gaps: GapList()..append(1, 2),
      ),
      throwsArgumentError,
    );
  });

  test('unit availability uses the actual channel count', () {
    expect(buildFixture().unitAvailability, (
      boardHasNominals: false,
      anyChannelHasLoadCell: false,
    ));

    final fiveChannelData = sessionDataFixture(
      channels: [
        for (var ch = 0; ch < 5; ch++) Int32List.fromList([0]),
      ],
      sampleRate: 1000,
      calibrations: [
        for (var ch = 0; ch < 5; ch++)
          ChannelCalibration(
            board: null,
            loadCell: ch == 4
                ? const LoadCellProfile(capacityKg: 100, sensitivityMvV: 2)
                : null,
          ),
      ],
      tares: List.filled(5, null),
    );
    expect(fiveChannelData.unitAvailability, (
      boardHasNominals: false,
      anyChannelHasLoadCell: true,
    ));
  });

  test('preparation snapshots calibrations and freezes its list views', () {
    const original = ChannelCalibration(board: null);
    final calibrations = [original];
    final prepared = decodeAndPrepareSession(
      codec: const SessionChunkCodec(1),
      bytes: Uint8List(4),
      calibrations: calibrations,
    );

    calibrations[0] = const ChannelCalibration(
      board: null,
      loadCell: LoadCellProfile(capacityKg: 100, sensitivityMvV: 2),
    );
    final data = SessionData.fromPrepared(
      prepared: prepared,
      sampleRate: 1000,
      tares: const [null],
      ssnOrigin: 0,
    );

    expect(data.calibrationFor(0), same(original));
    expect(prepared.channels.clear, throwsUnsupportedError);
    expect(prepared.calibrations.clear, throwsUnsupportedError);
    expect(prepared.valueBuckets.clear, throwsUnsupportedError);
    expect(prepared.diffBuckets.clear, throwsUnsupportedError);
    expect(prepared.extremes.clear, throwsUnsupportedError);
  });

  test('loaded data snapshots mutable list arguments', () {
    final channels = [
      Int32List.fromList([1, 2, 3]),
    ];
    final calibrations = [const ChannelCalibration(board: null)];
    final tares = <double?>[null];
    final data = sessionDataFixture(
      channels: channels,
      sampleRate: 1000,
      calibrations: calibrations,
      tares: tares,
    );

    channels.clear();
    calibrations.clear();
    tares[0] = 10;
    expect(data.channels, hasLength(1));
    expect(data.calibrations, hasLength(1));
    expect(data.tares, [null]);
    expect(data.channels.clear, throwsUnsupportedError);
    expect(data.calibrations.clear, throwsUnsupportedError);
    expect(data.tares.clear, throwsUnsupportedError);
  });
}
