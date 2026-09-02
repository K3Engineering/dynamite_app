import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/live_session_writer.dart';

/// SessionChunkCodec sentinel additions (live_session_writer.dart): the
/// 24-bit contract on pack, whole-frame gap sentinels, and the decode that
/// turns sentinel runs back into a GapList with held values.
void main() {
  const channels = 4;
  const codec = SessionChunkCodec(channels);

  Uint8List packFrames(List<List<int>> frames) =>
      codec.pack(frames.length, (s, ch) => frames[s][ch]);

  group('pack enforces the 24-bit contract', () {
    test('accepts the boundary values', () {
      final bytes = packFrames([
        [SessionChunkCodec.maxAdcValue, SessionChunkCodec.minAdcValue, 0, 1],
      ]);
      final view = ByteData.sublistView(bytes);
      expect(view.getInt32(0, Endian.little), SessionChunkCodec.maxAdcValue);
      expect(view.getInt32(4, Endian.little), SessionChunkCodec.minAdcValue);
    });

    test('rejects values outside the ADC range — encoder bug', () {
      expect(
        () => packFrames([
          [SessionChunkCodec.maxAdcValue + 1, 0, 0, 0],
        ]),
        throwsArgumentError,
      );
      expect(
        () => packFrames([
          [0, 0, 0, SessionChunkCodec.minAdcValue - 1],
        ]),
        throwsArgumentError,
      );
      // The sentinel in particular must never be packable as a real value.
      expect(
        () => packFrames([
          [SessionChunkCodec.gapSentinel, 0, 0, 0],
        ]),
        throwsArgumentError,
      );
    });
  });

  group('gap sentinels', () {
    final frames = [
      [10, 20, 30, 40],
      [11, 21, 31, 41], // gap
      [12, 22, 32, 42], // gap
      [13, 23, 33, 43],
      [14, 24, 34, 44], // gap
    ];

    test('decodeWithGaps recovers gaps and hold-fills channels', () {
      final bytes = packFrames(frames);
      codec.fillGapSentinels(bytes, [(1, 3), (4, 5)]);
      final decoded = codec.decodeWithGaps(bytes);

      expect(decoded.gaps.toJson(), '[[1,3],[4,5]]');
      // Gap frames hold the previous real value (frame 0 at first; the
      // last real frame 3 for the second gap).
      for (int ch = 0; ch < channels; ch++) {
        expect(decoded.channels[ch][1], frames[0][ch]);
        expect(decoded.channels[ch][2], frames[0][ch]);
        expect(decoded.channels[ch][4], frames[3][ch]);
      }
      // Real frames round-trip exactly.
      for (final s in [0, 3]) {
        for (int ch = 0; ch < channels; ch++) {
          expect(decoded.channels[ch][s], frames[s][ch]);
        }
      }
    });

    test('a gap running to the last frame closes at the frame count', () {
      final bytes = packFrames(frames);
      codec.fillGapSentinels(bytes, [(3, 5)]);
      expect(codec.decodeWithGaps(bytes).gaps.toJson(), '[[3,5]]');
    });

    test('adjacent gap ranges merge in the decoded GapList', () {
      final bytes = packFrames(frames);
      codec.fillGapSentinels(bytes, [(1, 2), (2, 4)]);
      expect(codec.decodeWithGaps(bytes).gaps.toJson(), '[[1,4]]');
    });

    test('trailing partial bytes throw — a torn tail is damage', () {
      final bytes = Uint8List.fromList([
        ...packFrames(frames.sublist(0, 2)),
        1,
        2,
        3,
      ]);
      expect(() => codec.decodeWithGaps(bytes), throwsStateError);
    });

    test('a non-sentinel value outside the ADC range throws', () {
      final bytes = packFrames(frames);
      ByteData.sublistView(
        bytes,
      ).setInt32(8, SessionChunkCodec.maxAdcValue + 1, Endian.little);
      expect(() => codec.decodeWithGaps(bytes), throwsStateError);

      final bytes2 = packFrames(frames);
      ByteData.sublistView(
        bytes2,
      ).setInt32(4, SessionChunkCodec.minAdcValue - 1, Endian.little);
      expect(() => codec.decodeWithGaps(bytes2), throwsStateError);
    });

    test('a sentinel first frame throws — hold-fill has no predecessor', () {
      final bytes = packFrames(frames);
      codec.fillGapSentinels(bytes, [(0, 1)]);
      expect(() => codec.decodeWithGaps(bytes), throwsStateError);
    });

    test('a frame mixing sentinel and real values throws', () {
      final bytes = packFrames(frames);
      ByteData.sublistView(
        bytes,
      ).setInt32(0, SessionChunkCodec.gapSentinel, Endian.little);
      expect(() => codec.decodeWithGaps(bytes), throwsStateError);
    });

    test('fillGapSentinels validates its ranges', () {
      final bytes = packFrames(frames);
      expect(() => codec.fillGapSentinels(bytes, [(4, 6)]), throwsRangeError);
      expect(() => codec.fillGapSentinels(bytes, [(2, 2)]), throwsRangeError);
      expect(() => codec.fillGapSentinels(bytes, [(-1, 1)]), throwsRangeError);
    });
  });
}
