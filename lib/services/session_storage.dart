import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import 'database.dart';
import 'live_session_writer.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import 'session_data.dart';
import 'session_metadata.dart';
import 'session_persistence.dart';

/// Each [SessionChunks] row holds a whole number of samples in the packed
/// chunk format (see [SessionChunkCodec], its one home, in
/// live_session_writer.dart). The owning [Sessions] row carries all metadata
/// (channel count, sample rate, calibration, etc.).
class SessionStorage {
  /// Start a new streaming session. The returned [LiveSessionWriter] is fed
  /// sample slices via [LiveSessionWriter.appendData] as data arrives and is
  /// passed to [finalizeSession] when recording stops.
  ///
  /// Note: every session stores all [kAdcChannelCount]; [channelLabels]
  /// and [visibleChannels] are retained for display only. [deviceMetadata] is
  /// the connected device's identity (see [toSessionDeviceMetadata]), frozen
  /// for export.
  ///
  /// This is hub-agnostic by contract: the caller snapshots everything the
  /// live buffer would supply ([tare], [channelCalibration],
  /// [samplesPerSec], [sourceRingCapacity]), so the storage layer never
  /// imports the hub.
  static Future<LiveSessionWriter> startSession({
    required Float64List tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
  }) async {
    // Snapshot the tare once; the same values are persisted below and used by
    // the writer's peak scan, so stored peaks, stored tares and playback can
    // never disagree even if the user re-tares mid-recording.
    final tareSnapshot = Float64List.fromList(tare);

    final sessionId = await AppDatabase.instance.createSession(
      name: name,
      sampleRate: samplesPerSec,
      // We always persist every ADC channel, so the stored channel count must
      // match what the writer packs (and what loadSession reads back).
      channelCount: kAdcChannelCount,
      channelLabels: jsonEncode(channelLabels),
      tares: jsonEncode(tareSnapshot.toList()),
      // Snapshot the per-channel calibration in effect now; playback
      // converts through it even if calibration changes later.
      calibrationJson: jsonEncode([
        for (int ch = 0; ch < kAdcChannelCount; ch++)
          channelCalibration[ch].toJson(),
      ]),
      visibleChannels: jsonEncode(visibleChannels),
      // Frozen as the CSV export's default converted unit
      // (docs/csv-format-v1.md's recording-time snapshot requirement).
      displayUnit: displayUnit.name,
      deviceInfoJson: jsonEncode(deviceMetadata),
    );

    return LiveSessionWriter(
      sessionId,
      tareSnapshot,
      samplesPerSec,
      sourceRingCapacity: sourceRingCapacity,
    );
  }

  /// Discard a session that was created but never latched by its caller
  /// (e.g. the link dropped while its row was being inserted — see
  /// `RecordingController.startSession`). The writer has written no chunks,
  /// so this is a plain row delete, not a recovery case.
  static Future<void> discardSession(LiveSessionWriter writer) =>
      AppDatabase.instance.deleteSession(writer.sessionId);

  /// Finalize a streaming session: flush any buffered samples, then record the
  /// aggregates the writer accumulated and mark the session completed.
  ///
  /// Returns the writer's latched write error (if any). When non-null, the
  /// session may be short/truncated; the caller should surface it.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
  }) async {
    await writer.flush();

    await _completeSession(
      sessionId: writer.sessionId,
      sampleCount: writer.totalSamplesRecorded,
      sampleRate: writer.sampleRate,
      peaksRaw: writer.peaksRaw,
      gapsJson: writer.gaps.toJson(),
    );

    return writer.writeError;
  }

  /// Write a finished (or recovered) session's aggregates to its row and mark
  /// it completed. Shared by [finalizeSession] and [recoverIncompleteSessions]
  /// so both paths apply identical guards and duration math.
  static Future<void> _completeSession({
    required int sessionId,
    required int sampleCount,
    required int sampleRate,
    required List<double> peaksRaw,
    required String gapsJson,
  }) {
    return AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: sampleCount,
      durationMs: (sampleCount * 1000) ~/ sampleRate,
      // A channel that captured no samples leaves its peak at -infinity;
      // that must not reach the DB.
      peaksRaw: jsonEncode([for (final p in peaksRaw) p.isFinite ? p : 0.0]),
      gaps: gapsJson,
    );
  }

  /// Recovers any sessions left incomplete (e.g. the app crashed mid-recording)
  /// by scanning their persisted chunks to rebuild aggregates and marking them
  /// completed. Sessions with no chunks are deleted.
  static Future<void> recoverIncompleteSessions() async {
    final incomplete = await AppDatabase.instance.incompleteSessions();

    for (final session in incomplete) {
      debugPrint('Recovering incomplete session: ${session.id}');

      final chunks = await AppDatabase.instance.sessionChunkData(session.id);

      if (chunks.isEmpty) {
        // Started but never wrote a chunk. Nothing to keep.
        await AppDatabase.instance.deleteSession(session.id);
        continue;
      }

      // Rebuild aggregates against the tare persisted at recording start, the
      // same one loadSession applies, so recovered peaks match playback.
      final agg = SessionChunkAggregate(session.channelCount);
      final tare = _parseTares(session.tares, session.channelCount);
      for (final chunk in chunks) {
        agg.scan(chunk, tare);
      }

      // Preserve the gaps persisted incrementally by the live writer (chunk
      // bytes alone can't reconstruct them).
      await _completeSession(
        sessionId: session.id,
        sampleCount: agg.samples,
        // Recovery uses the rate persisted on the row (finalize uses the
        // writer's, which is the same value from recording start) so a future
        // configurable rate can't skew reconstructed durations.
        sampleRate: session.sampleRate,
        peaksRaw: agg.peaksRaw,
        gapsJson: session.gaps,
      );
    }
  }

  /// Read a session's recorded data back from its chunks.
  ///
  /// TODO(perf): this materializes every chunk blob AND the full
  /// deinterleaved channel arrays (~2x session size transiently — a 1-hour
  /// session is ~58 MB of samples). If long sessions become common, stream
  /// the deinterleave (and consider isolating the [SessionData] stats scan,
  /// which currently runs eagerly on the UI thread below).
  static Future<SessionData?> loadSession(int sessionId) async {
    final row = await AppDatabase.instance.sessionById(sessionId);
    if (row == null) {
      throw StateError('loadSession: no session row with id $sessionId');
    }
    final session = row;
    final chunks = await AppDatabase.instance.sessionChunkData(session.id);

    if (chunks.isEmpty) {
      debugPrint('No chunks found for session: ${session.id}');
      return null;
    }

    final channelCount = session.channelCount;
    final sampleCount = session.sampleCount;
    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));
    final codec = SessionChunkCodec(channelCount);

    int globalS = 0;
    for (final chunk in chunks) {
      // Frames beyond the metadata's sampleCount are silently truncated
      // (chunk/metadata disagreement is not surfaced today).
      codec.decode(chunk, (s, ch, raw) {
        final g = globalS + s;
        if (g < sampleCount) channels[ch][g] = raw;
      });
      globalS += codec.framesOf(chunk);
      if (globalS >= sampleCount) break;
    }

    return SessionData(
      channels: channels,
      sampleRate: session.sampleRate,
      sampleCount: globalS,
      calibrations: _parseCalibrations(session.calibrationJson, channelCount),
      tares: _parseTares(session.tares, channelCount),
      gaps: GapList.fromJson(session.gaps),
      ssnOrigin: session.ssnOrigin,
    );
  }

  /// Parse the JSON-encoded per-channel tares stored on a [Session] row.
  /// Missing or malformed entries fall back to zero.
  static Float64List _parseTares(String json, int channelCount) =>
      Float64List.fromList(
        parseJsonColumn(
          json,
          channelCount,
          convert: (e) => (e as num).toDouble(),
          fallback: (_) => 0.0,
        ),
      );

  /// Parse the JSON-encoded per-channel calibration snapshots stored on a
  /// [Session] row. Missing or malformed entries fall back to a nominal
  /// board with no load cell (electrical units only).
  static List<ChannelCalibration> _parseCalibrations(
    String json,
    int channelCount,
  ) => parseJsonColumn(
    json,
    channelCount,
    convert: (e) =>
        ChannelCalibration.fromJson(Map<String, dynamic>.from(e as Map)),
    fallback: (_) => ChannelCalibration(board: ChannelBoardCalibration()),
  );
}

/// Adapts the [SessionStorage] statics to the [SessionPersistence] port
/// `RecordingController` consumes (main wires this in; recording tests can
/// double the interface instead).
class StaticSessionPersistence implements SessionPersistence {
  const StaticSessionPersistence();

  @override
  Future<LiveSessionWriter> startSession({
    required Float64List tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
  }) => SessionStorage.startSession(
    tare: tare,
    channelCalibration: channelCalibration,
    samplesPerSec: samplesPerSec,
    sourceRingCapacity: sourceRingCapacity,
    name: name,
    channelLabels: channelLabels,
    visibleChannels: visibleChannels,
    displayUnit: displayUnit,
    deviceMetadata: deviceMetadata,
  );

  @override
  Future<void> discardSession(LiveSessionWriter writer) =>
      SessionStorage.discardSession(writer);

  @override
  Future<Object?> finalizeSession({required LiveSessionWriter writer}) =>
      SessionStorage.finalizeSession(writer: writer);
}
