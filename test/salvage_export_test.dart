import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/salvage_export.dart';

/// Tests for the pure salvage-CSV builder (delivery half is platform code).
/// Format reference: docs/csv-format-v1.md's salvage appendix.
void main() {
  const int channels = kAdcChannelCount;
  const codec = SessionChunkCodec(channels);

  setUp(() {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(AppDatabase.closeInstance);

  Uint8List packChunk(List<List<int>> frames) =>
      codec.pack(frames.length, (s, ch) => frames[s][ch]);

  /// A completed session row with chunks inserted at [chunkIndices].
  Future<int> makeSessionRow({
    required List<Uint8List> chunks,
    required int sampleCount,
    List<int>? chunkIndices,
    String gaps = '[]',
    int ssnOrigin = 41230,
  }) async {
    final id = await AppDatabase.instance.createSession(
      name: 'salvage',
      sampleRate: 1000,
      channelCount: channels,
      channelLabels: '[]',
      tares: '[0,0,0,0]',
      calibrationJson: '[]',
      visibleChannels: '[]',
      displayUnit: 'kgf',
      deviceInfoJson: '{}',
      ssnOrigin: ssnOrigin,
    );
    final indices = chunkIndices ?? [for (var i = 0; i < chunks.length; i++) i];
    for (var i = 0; i < chunks.length; i++) {
      await AppDatabase.instance.insertChunk(id, indices[i], chunks[i]);
    }
    await AppDatabase.instance.completeSession(
      id,
      sampleCount: sampleCount,
      durationMs: 1,
      gaps: gaps,
    );
    return id;
  }

  Future<List<String>> salvageLines(int id) async => (await buildSalvageCsv(
    sessionId: id,
    generator: 'test 0.0',
  ))!.trim().split('\n');

  Map<String, dynamic> metadataOf(List<String> lines) {
    expect(lines[0], '# dynamite-csv-salvage 1');
    expect(lines[1], startsWith('# '));
    return jsonDecode(lines[1].substring(2)) as Map<String, dynamic>;
  }

  test('a healthy session has nothing to salvage', () async {
    final id = await makeSessionRow(
      chunks: [
        packChunk([
          [1, 2, 3, 4],
        ]),
      ],
      sampleCount: 1,
    );
    expect(await buildSalvageCsv(sessionId: id, generator: 'test'), isNull);
  });

  test('a missing middle chunk salvages the suffix, unpositioned', () async {
    final id = await makeSessionRow(
      chunks: [
        packChunk([
          [1, 1, 1, 1],
          [2, 2, 2, 2],
        ]),
        packChunk([
          [9, 9, 9, 9],
        ]),
      ],
      chunkIndices: [0, 2], // index 1 missing
      sampleCount: 3,
      gaps: '[[1,3]]',
    );

    final lines = await salvageLines(id);
    final meta = metadataOf(lines);
    expect(meta['verified_prefix_samples'], 2);
    expect(meta.containsKey('unaligned_chunk'), isFalse);
    // Clean gaps ride along as re-anchoring hints.
    expect(meta['gap_ranges'], [
      [1, 3],
    ]);
    expect(lines[2], 'ssn,chunk,frame,ch0,ch1,ch2,ch3');
    // The suffix frame has no knowable position: blank ssn, storage coords.
    expect(lines[3], ',2,0,9,9,9,9');
    expect(lines, hasLength(4));
  });

  test(
    'frames beyond the metadata count salvage with their real ssn',
    () async {
      final id = await makeSessionRow(
        chunks: [
          packChunk([
            [1, 1, 1, 1],
            [2, 2, 2, 2],
            [3, 3, 3, 3],
          ]),
        ],
        sampleCount: 2, // chunks hold 3 frames; metadata claims 2
      );

      final lines = await salvageLines(id);
      expect(metadataOf(lines)['verified_prefix_samples'], 2);
      // The overflow frame's position is intact (chunks are contiguous).
      expect(lines[3], '41232,0,2,3,3,3,3');
      expect(lines, hasLength(4));
    },
  );

  test('a misaligned blob salvages its whole frames, named; trailing partial '
      'bytes are undeliverable', () async {
    final misaligned = BytesBuilder()
      ..add(
        packChunk([
          [7, 7, 7, 7],
          [8, 8, 8, 8],
        ]),
      )
      ..add([1, 2, 3]); // partial trailing frame: never exported
    final id = await makeSessionRow(
      chunks: [
        packChunk([
          [1, 1, 1, 1],
        ]),
        misaligned.toBytes(),
      ],
      sampleCount: 3,
    );

    final lines = await salvageLines(id);
    final meta = metadataOf(lines);
    expect(meta['verified_prefix_samples'], 1);
    expect(meta['unaligned_chunk'], 1);
    // The misaligned chunk is still in the contiguous run, so its whole
    // frames keep their ssn — flagged suspect, but positionable.
    expect(lines[3], '41231,1,0,7,7,7,7');
    expect(lines[4], '41232,1,1,8,8,8,8');
    expect(lines, hasLength(5)); // no row for the 3 stray bytes
  });

  test(
    'damage at chunk 0 salvages the whole recording, verified_prefix 0',
    () async {
      final id = await makeSessionRow(
        chunks: [
          packChunk([
            [5, 5, 5, 5],
          ]),
          packChunk([
            [6, 6, 6, 6],
          ]),
        ],
        chunkIndices: [1, 2], // chunk 0 missing
        sampleCount: 3,
      );

      final lines = await salvageLines(id);
      expect(metadataOf(lines)['verified_prefix_samples'], 0);
      expect(lines[3], ',1,0,5,5,5,5');
      expect(lines[4], ',2,0,6,6,6,6');
    },
  );

  test('a corrupt gaps column is simply omitted from the metadata', () async {
    final id = await makeSessionRow(
      chunks: [
        packChunk([
          [1, 1, 1, 1],
        ]),
      ],
      chunkIndices: [1],
      sampleCount: 1,
      gaps: '[[10,5]]', // inverted: strict parse throws
    );
    final meta = metadataOf(await salvageLines(id));
    expect(meta.containsKey('gap_ranges'), isFalse);
  });
}
