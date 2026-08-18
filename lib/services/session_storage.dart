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
  /// passed to [finalizeSession] when recording stops. Pure construction —
  /// the session row is only created by the writer's first chunk flush, so
  /// starting can never fail and never leaves a row behind without data.
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
  static LiveSessionWriter startSession({
    required Float64List tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
  }) {
    // Snapshot the tare once and persist it with the session; playback
    // converts through it, so a later re-tare can never rewrite history.
    final tareSnapshot = Float64List.fromList(tare);

    return LiveSessionWriter(
      (
        name: name,
        sampleRate: samplesPerSec,
        // We always persist every ADC channel, so the stored channel count
        // must match what the writer packs (and what loadSession reads back).
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
      ),
      sourceRingCapacity: sourceRingCapacity,
    );
  }

  /// Finalize a streaming session: flush any buffered samples, then record
  /// the final sample count and mark the session completed.
  ///
  /// If no data ever reached storage, the session row was never created and
  /// there is nothing to finalize (recording nothing saves nothing).
  ///
  /// Returns the writer's latched write error (if any). When non-null, the
  /// session may be short/truncated; the caller should surface it.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
  }) async {
    await writer.flush();

    final sessionId = writer.sessionId;
    if (sessionId != null) {
      await _completeSession(
        sessionId: sessionId,
        sampleCount: writer.totalSamplesRecorded,
        sampleRate: writer.sampleRate,
        gapsJson: writer.gaps.toJson(),
      );
    }

    return writer.writeError;
  }

  /// Write a finished (or recovered) session's final sample count and mark it
  /// completed. Shared by [finalizeSession] and [recoverIncompleteSessions]
  /// so both paths apply identical duration math.
  static Future<void> _completeSession({
    required int sessionId,
    required int sampleCount,
    required int sampleRate,
    required String gapsJson,
  }) {
    return AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: sampleCount,
      durationMs: (sampleCount * 1000) ~/ sampleRate,
      gaps: gapsJson,
    );
  }

  /// Recovers any sessions left incomplete (e.g. the app crashed mid-recording)
  /// by counting their persisted frames and marking them completed. A
  /// production session row only exists alongside its first chunk (see
  /// [AppDatabase.createSessionWithFirstChunk]), so "incomplete and
  /// dataless" cannot occur.
  static Future<void> recoverIncompleteSessions() async {
    final incomplete = await AppDatabase.instance.incompleteSessions();

    for (final session in incomplete) {
      debugPrint('Recovering incomplete session: ${session.id}');

      final chunks = await AppDatabase.instance.sessionChunkData(session.id);

      // The sample count comes from chunk byte lengths — recovery never
      // decodes samples (and couldn't reconstruct gaps either; those stay as
      // the live writer persisted them).
      final codec = SessionChunkCodec(session.channelCount);
      int sampleCount = 0;
      for (final chunk in chunks) {
        sampleCount += codec.framesOf(chunk);
      }

      // Preserve the gaps persisted incrementally by the live writer (chunk
      // bytes alone can't reconstruct them).
      await _completeSession(
        sessionId: session.id,
        sampleCount: sampleCount,
        // Recovery uses the rate persisted on the row (finalize uses the
        // writer's, which is the same value from recording start) so a future
        // configurable rate can't skew reconstructed durations.
        sampleRate: session.sampleRate,
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
  LiveSessionWriter startSession({
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
  Future<Object?> finalizeSession({required LiveSessionWriter writer}) =>
      SessionStorage.finalizeSession(writer: writer);
}
