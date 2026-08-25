/// Salvage export: every decodable sample that integrity verification
/// excluded from the session view and the primary CSV (see
/// [verifyChunkIntegrity]), emitted as raw counts for human hand-recovery.
///
/// The salvage file is deliberately NOT dynamite-csv: the primary format's
/// contract (an arithmetic `ssn` progression, converted columns
/// reproducible from metadata) can only vouch for verified data. The
/// salvage file relaxes exactly that: rows past a chunk hole carry no
/// `ssn` (their position is unknowable), and frames from a misaligned blob
/// are included and named, because the verifier here is a human, not the
/// app. Nothing decodable is ever withheld from the user.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../models/app_meta.dart';
import '../models/gap_list.dart';
import '../utils/format.dart';
import 'database.dart';
import 'export_delivery.dart';
import 'export_names.dart';
import 'live_session_writer.dart';
import 'session_metadata.dart';

/// Export all decodable samples outside the session's verified prefix as a
/// salvage CSV. Independent of [SessionStorage.loadSession] by design: it
/// reads the rows and chunks directly, so it works even (especially) when
/// the session view fails to load — and it never fabricates positions.
///
/// Returns the delivery result message ([downloadExport]), or a
/// nothing-to-salvage message when every chunk verifies and nothing lies
/// outside the prefix.
Future<String?> downloadSalvageCsv({
  required int sessionId,
  required String sessionName,
  required AppMeta appMeta,
}) async {
  final csv = await buildSalvageCsv(
    sessionId: sessionId,
    generator: appMeta.generator,
  );
  if (csv == null) {
    return 'No salvageable data: every recorded sample is in the session '
        'export already';
  }
  return downloadExport(
    bytes: Uint8List.fromList(utf8.encode(csv)),
    fileName: exportFileNameFor(
      sessionName,
      'salvage.csv',
      fallback: 'session_salvage',
    ),
    dialogTitle: salvageExportLabel,
  );
}

/// Build the salvage CSV for one session ('# dynamite-csv-salvage 1'
/// magic, a one-line metadata JSON, then `ssn,chunk,frame,chN…` rows).
/// Null when nothing is salvageable — every chunk verifies and no frame
/// lies outside the verified prefix (a healthy session salvage-exports
/// nothing).
///
/// Throws when the session row does not exist.
Future<String?> buildSalvageCsv({
  required int sessionId,
  required String generator,
}) async {
  final row = await AppDatabase.instance.sessionById(sessionId);
  if (row == null) {
    throw StateError('buildSalvageCsv: no session row with id $sessionId');
  }
  final chunks = await AppDatabase.instance.sessionChunkRows(sessionId);
  final codec = SessionChunkCodec(row.channelCount);
  final integrity = verifyChunkIntegrity(codec, [
    for (final c in chunks) (c.chunkIndex, c.data),
  ]);

  // The verified extent, matching SessionStorage.loadSession's rule:
  // frames below this index are already in the primary CSV.
  final verified = integrity.prefixFrames < row.sampleCount
      ? integrity.prefixFrames
      : row.sampleCount;

  // Walk every chunk. Frames of the contiguous run (indices 0,1,2,…
  // decodable in order) keep their session-relative position — including
  // frames beyond [verified] from a count disagreement, and whole frames
  // of the misaligned blob the walk stopped at. Once the run breaks (hole
  // or misalignment), later chunks' positions are unknowable: blank `ssn`.
  final rows = StringBuffer();
  var expected = 0;
  var sessionIndex = 0; // position within the contiguous run
  var positioningLost = false;
  int? unalignedChunk;
  var salvageCount = 0;
  final frame = Int32List(row.channelCount);
  for (final c in chunks) {
    final aligned = c.data.lengthInBytes % codec.frameBytes == 0;
    final inRun = !positioningLost && c.chunkIndex == expected;
    if (inRun && !aligned) unalignedChunk = c.chunkIndex;
    final frames = codec.framesOf(c.data);
    codec.decode(c.data, (s, ch, raw) {
      frame[ch] = raw;
      if (ch != row.channelCount - 1) return; // emit at the frame's end
      final pos = inRun ? sessionIndex + s : null;
      if (pos != null && pos < verified) return; // in the primary CSV
      rows.write(pos == null ? '' : '${row.ssnOrigin + pos}');
      rows.write(',${c.chunkIndex},$s');
      for (var k = 0; k < row.channelCount; k++) {
        rows.write(',${frame[k]}');
      }
      rows.writeln();
      salvageCount++;
    });
    if (inRun) {
      sessionIndex += frames;
      expected++;
      if (!aligned) positioningLost = true;
    } else {
      positioningLost = true;
    }
  }

  if (salvageCount == 0) return null;

  // Metadata side info that survives strict parsing — honest context for
  // whoever hand-recovers. Gap ranges are session-relative anchors (a
  // human can re-anchor a positionless suffix against them); a corrupt
  // gaps column is simply omitted.
  List<List<int>>? gapRanges;
  try {
    gapRanges = [
      for (final (s, e) in GapList.fromJson(row.gaps).rangesIn(0, 1 << 62))
        [s, e],
    ];
  } on FormatException {
    gapRanges = null;
  }

  final metadata = <String, Object?>{
    'format': 'dynamite-csv-salvage',
    'version': 1,
    'generator': generator,
    'recorded_at': row.createdAt.toUtc().toIso8601String(),
    'sample_rate_hz': row.sampleRate,
    'ssn_origin': row.ssnOrigin,
    'verified_prefix_samples': verified,
    'unaligned_chunk': ?unalignedChunk,
    if (gapRanges case final g? when g.isNotEmpty) 'gap_ranges': g,
    'device': fromSessionDeviceMetadata(row.deviceInfoJson),
  };

  final buf = StringBuffer()
    ..writeln('# dynamite-csv-salvage 1')
    ..writeln('# ${jsonEncode(metadata)}')
    ..write('ssn,chunk,frame');
  for (var ch = 0; ch < row.channelCount; ch++) {
    buf.write(',ch$ch');
  }
  buf
    ..writeln()
    ..write(rows);
  return buf.toString();
}
