import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import 'database.dart';
import 'live_session_writer.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import 'session_data.dart';
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

    return LiveSessionWriter((
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
    ), sourceRingCapacity: sourceRingCapacity);
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
  ///
  /// Chunk integrity is verified the same way [loadSession] does: a damaged
  /// tail (missing index, misaligned blob) is NOT counted — the session
  /// completes with its verified prefix and clamped gaps. The damaged
  /// chunks stay on disk, so later loads re-flag the truncation and the
  /// salvage export can recover them.
  static Future<void> recoverIncompleteSessions() async {
    final incomplete = await AppDatabase.instance.incompleteSessions();

    for (final session in incomplete) {
      debugPrint('Recovering incomplete session: ${session.id}');

      final chunks = await AppDatabase.instance.sessionChunkRows(session.id);

      // The sample count comes from verified chunk byte lengths — recovery
      // never decodes samples (and couldn't reconstruct gaps either; those
      // stay as the live writer persisted them, clamped to the prefix).
      final codec = SessionChunkCodec(session.channelCount);
      final integrity = verifyChunkIntegrity(codec, [
        for (final c in chunks) (c.chunkIndex, c.data),
      ]);
      if (integrity.stoppedEarly) {
        debugPrint(
          'Session ${session.id}: chunk integrity failed at sample '
          '${integrity.prefixFrames}; completing the verified prefix',
        );
      }

      // A corrupt gaps column is left untouched for loadSession to flag —
      // recovery cannot repair it, only refrain from masking it.
      String gapsJson = session.gaps;
      try {
        gapsJson = GapList.fromJson(
          session.gaps,
        ).clampedTo(integrity.prefixFrames).toJson();
      } on FormatException {
        debugPrint('Session ${session.id}: gaps column is corrupt');
      }

      await _completeSession(
        sessionId: session.id,
        sampleCount: integrity.prefixFrames,
        // Recovery uses the rate persisted on the row (finalize uses the
        // writer's, which is the same value from recording start) so a future
        // configurable rate can't skew reconstructed durations.
        sampleRate: session.sampleRate,
        gapsJson: gapsJson,
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
    final chunks = await AppDatabase.instance.sessionChunkRows(session.id);

    if (chunks.isEmpty) {
      debugPrint('No chunks found for session: ${session.id}');
      return null;
    }

    final channelCount = session.channelCount;
    final codec = SessionChunkCodec(channelCount);
    final integrity = verifyChunkIntegrity(codec, [
      for (final c in chunks) (c.chunkIndex, c.data),
    ]);

    // No honest subset: the damage starts at the first frame, so no view
    // shape can vouch for anything (the salvage export may still recover
    // raw samples). Zero-frame chunks with a zero metadata count are NOT
    // this case — they verify clean and load as an empty session.
    if (integrity.stoppedEarly && integrity.prefixFrames == 0) {
      throw StateError(
        'Session $sessionId: chunk data damaged from the first chunk — '
        'no verifiable data to display',
      );
    }

    // The honest extent: disagreement between chunks and the metadata's
    // sample count truncates to whichever claims less (both directions
    // fabricate otherwise — overflow poses never-recorded samples as data,
    // underflow splices).
    final sampleCount = math.min(integrity.prefixFrames, session.sampleCount);
    final truncatedAt = integrity.stoppedEarly
        ? integrity.prefixFrames
        : (integrity.prefixFrames != session.sampleCount ? sampleCount : null);
    if (truncatedAt != null) {
      debugPrint(
        'Session $sessionId: chunk integrity damage — truncating to '
        '$sampleCount verified samples',
      );
    }

    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));

    int globalS = 0;
    for (final c in chunks.take(integrity.prefixChunks)) {
      codec.decode(c.data, (s, ch, raw) {
        final g = globalS + s;
        if (g < sampleCount) channels[ch][g] = raw;
      });
      globalS += codec.framesOf(c.data);
      if (globalS >= sampleCount) break;
    }

    // Metadata columns parse strictly at this boundary: each damaged column
    // floors to its honest degraded state (see SessionDamage) and sets its
    // flag — salvage per entry would fabricate values indistinguishable
    // from legitimate recorded ones (a zero tare IS a valid recording).
    var tareDamaged = false;
    Float64List tares;
    try {
      tares = _parseTares(session.tares, channelCount);
    } on FormatException catch (e) {
      debugPrint('Session $sessionId: tares damaged ($e)');
      tareDamaged = true;
      tares = Float64List(channelCount);
    }

    var calibrationDamaged = false;
    List<ChannelCalibration> calibrations;
    try {
      calibrations = _parseCalibrations(session.calibrationJson, channelCount);
    } on FormatException catch (e) {
      debugPrint('Session $sessionId: calibration damaged ($e)');
      calibrationDamaged = true;
      calibrations = [
        for (int ch = 0; ch < channelCount; ch++)
          ChannelCalibration(board: ChannelBoardCalibration()),
      ];
    }

    var gapsLost = false;
    GapList gaps;
    try {
      gaps = GapList.fromJson(session.gaps).clampedTo(sampleCount);
    } on FormatException catch (e) {
      debugPrint('Session $sessionId: gaps damaged ($e)');
      gapsLost = true;
      gaps = GapList();
    }

    return SessionData(
      channels: channels,
      sampleRate: session.sampleRate,
      sampleCount: sampleCount,
      calibrations: calibrations,
      tares: tares,
      gaps: gaps,
      ssnOrigin: session.ssnOrigin,
      damage: SessionDamage(
        tare: tareDamaged,
        calibration: calibrationDamaged,
        gapsLost: gapsLost,
        truncatedAt: truncatedAt,
      ),
    );
  }

  /// Parse the JSON-encoded per-channel tares stored on a [Session] row.
  /// Strict — exactly [channelCount] finite numbers, else [FormatException]
  /// (jsonDecode's own malformed-document exceptions included).
  static Float64List _parseTares(String json, int channelCount) {
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.length != channelCount) {
      throw FormatException('tares must be a list of $channelCount numbers');
    }
    return Float64List.fromList([
      for (final e in decoded)
        e is num && e.toDouble().isFinite
            ? e.toDouble()
            : throw const FormatException('tare entries must be numbers'),
    ]);
  }

  /// Parse the JSON-encoded per-channel calibration snapshots stored on a
  /// [Session] row. Strict — exactly [channelCount] well-formed entries
  /// (see [ChannelCalibration.fromJson]), else [FormatException].
  static List<ChannelCalibration> _parseCalibrations(
    String json,
    int channelCount,
  ) {
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.length != channelCount) {
      throw FormatException(
        'calibration must be a list of $channelCount entries',
      );
    }
    return [
      for (final e in decoded)
        ChannelCalibration.fromJson(
          e is Map
              ? Map<String, dynamic>.from(e)
              : throw const FormatException(
                  'calibration entries must be objects',
                ),
        ),
    ];
  }
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
