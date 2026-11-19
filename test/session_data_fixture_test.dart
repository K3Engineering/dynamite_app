import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/session_data.dart';

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

  test('passes out-of-bounds gaps to the codec without clamping them', () {
    expect(() => buildFixture(gaps: GapList()..append(3, 4)), throwsRangeError);
  });

  test('rejects an invalid sample rate or tare count', () {
    expect(() => buildFixture(sampleRate: 0), throwsArgumentError);
    expect(() => buildFixture(tares: const []), throwsArgumentError);
  });
}
