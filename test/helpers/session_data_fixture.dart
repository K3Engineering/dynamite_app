import 'dart:typed_data';

import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_data.dart';
import 'package:dynamite_app/services/session_preparation.dart';

/// Build a fixture through packed storage and the production decoder, keeping
/// channel values, gaps, and graph aggregates consistent by construction.
/// The decoder replaces values at gap indices with the preceding sample.
SessionData sessionDataFixture({
  required List<Int32List> channels,
  required int sampleRate,
  required List<ChannelCalibration> calibrations,
  required List<double?> tares,
  GapList? gaps,
  int ssnOrigin = 0,
  KvsSnapshot? deviceKvs,
}) {
  if (channels.isEmpty) {
    throw ArgumentError.value(channels, 'channels', 'must not be empty');
  }
  final count = channels.first.length;
  for (int ch = 1; ch < channels.length; ch++) {
    if (channels[ch].length != count) {
      throw ArgumentError.value(
        channels[ch].length,
        'channels[$ch]',
        'must have the same length as channels[0] ($count)',
      );
    }
  }
  final codec = SessionChunkCodec(channels.length);
  final bytes = codec.pack(count, (s, ch) => channels[ch][s]);
  codec.fillGapSentinels(bytes, gaps?.ranges ?? const []);
  return SessionData.fromPrepared(
    prepared: decodeAndPrepareSession(
      codec: codec,
      bytes: bytes,
      calibrations: calibrations,
    ),
    sampleRate: sampleRate,
    tares: tares,
    ssnOrigin: ssnOrigin,
    deviceKvs: deviceKvs,
  );
}
