import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'bt_handling.dart';

/// Binary file format:
/// - 4 bytes: magic "DYNO"
/// - 4 bytes: version (uint32 LE)
/// - 4 bytes: channel count (uint32 LE)
/// - 4 bytes: sample count (uint32 LE)
/// - 4 bytes: sample rate (uint32 LE)
/// - 4 bytes: reserved
/// - then: packed int32 LE values, interleaved [ch0_s0, ch1_s0, ch0_s1, ch1_s1, ...]
///
/// Total header: 24 bytes

class SessionStorage {
  static const int _headerSize = 24;
  static const int _version = 1;
  static final _magic = Uint8List.fromList([0x44, 0x59, 0x4E, 0x4F]); // "DYNO"

  /// Save the current DataHub contents to a binary DB blob and create a DB record.
  /// Only saves the slice from [dataHub.recordingStartIdx] to [dataHub.rawSz].
  /// Returns the session id.
  static Future<int> saveSession({
    required DataHub dataHub,
    required String name,
    required List<String> channelLabels,
    required int channelCount,
    String notes = '',
  }) async {
    final int startIdx = dataHub.recordingStartIdx;
    final int endIdx = dataHub.rawSz;
    final int recordedSamples = endIdx - startIdx;

    final blobData = _createBinaryData(
      dataHub: dataHub,
      startIdx: startIdx,
      sampleCount: recordedSamples,
    );

    // Compute peak over the recorded slice
    double peakRaw = 0;
    int peakChannel = 0;
    for (int line = 0; line < DataHub.numGraphLines; line++) {
      for (int s = startIdx; s < endIdx; s++) {
        final val = (dataHub.rawData[line][s] - dataHub.tare[line]);
        if (val > peakRaw) {
          peakRaw = val;
          peakChannel = line;
        }
      }
    }

    final durationMs = (recordedSamples * 1000) ~/ DataHub.samplesPerSec;

    // Create DB record
    final id = await AppDatabase.instance.transaction(() async {
      final sessionId = await AppDatabase.instance.insertSession(
        SessionsCompanion.insert(
          name: Value(name),
          createdAt: DateTime.now(),
          durationMs: Value(durationMs),
          sampleRate: const Value(DataHub.samplesPerSec),
          channelCount: Value(channelCount),
          channelLabels: Value(jsonEncode(channelLabels)),
          peakForceRaw: Value(peakRaw),
          peakForceChannel: Value(peakChannel),
          calibrationSlope: Value(dataHub.deviceCalibration.slope),
          calibrationOffset: Value(dataHub.deviceCalibration.offset),
          notes: Value(notes),
          sampleCount: Value(recordedSamples),
        ),
      );

      await AppDatabase.instance
          .into(AppDatabase.instance.sessionBlobs)
          .insert(
            SessionBlobsCompanion.insert(
              sessionId: Value(sessionId),
              data: blobData,
            ),
          );

      return sessionId;
    });

    return id;
  }

  /// Build the binary buffer.
  static Uint8List _createBinaryData({
    required DataHub dataHub,
    required int startIdx,
    required int sampleCount,
  }) {
    const numLines = DataHub.numGraphLines;

    // Build the binary buffer
    final totalBytes = _headerSize + sampleCount * numLines * 4;
    final buffer = ByteData(totalBytes);

    // Header
    for (int i = 0; i < 4; i++) {
      buffer.setUint8(i, _magic[i]);
    }
    buffer.setUint32(4, _version, Endian.little);
    buffer.setUint32(8, numLines, Endian.little);
    buffer.setUint32(12, sampleCount, Endian.little);
    buffer.setUint32(16, DataHub.samplesPerSec, Endian.little);
    buffer.setUint32(20, 0, Endian.little); // reserved

    // Interleaved data — write only from startIdx to startIdx + sampleCount
    int offset = _headerSize;
    for (int s = startIdx; s < startIdx + sampleCount; s++) {
      for (int ch = 0; ch < numLines; ch++) {
        buffer.setInt32(offset, dataHub.rawData[ch][s], Endian.little);
        offset += 4;
      }
    }

    return buffer.buffer.asUint8List();
  }

  /// Read a session's binary data from the DB.
  static Future<SessionData?> loadSession(Session session) async {
    final blob = await (AppDatabase.instance.select(
      AppDatabase.instance.sessionBlobs,
    )..where((t) => t.sessionId.equals(session.id))).getSingleOrNull();

    if (blob == null) {
      debugPrint('Session blob not found in DB for session: ${session.id}');
      return null;
    }

    final data = ByteData.sublistView(blob.data);

    // Validate header
    for (int i = 0; i < 4; i++) {
      if (data.getUint8(i) != _magic[i]) {
        debugPrint('Invalid file magic');
        return null;
      }
    }

    final version = data.getUint32(4, Endian.little);
    if (version != _version) {
      debugPrint('Unsupported version: $version');
      return null;
    }

    final channelCount = data.getUint32(8, Endian.little);
    final sampleCount = data.getUint32(12, Endian.little);
    final sampleRate = data.getUint32(16, Endian.little);

    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));

    int offset = _headerSize;
    for (int s = 0; s < sampleCount; s++) {
      for (int ch = 0; ch < channelCount; ch++) {
        channels[ch][s] = data.getInt32(offset, Endian.little);
        offset += 4;
      }
    }

    return SessionData(
      channels: channels,
      sampleRate: sampleRate,
      sampleCount: sampleCount,
      calibrationSlope: session.calibrationSlope,
      calibrationOffset: session.calibrationOffset,
    );
  }
}

/// Loaded session data for playback/review.
class SessionData {
  final List<Int32List> channels;
  final int sampleRate;
  final int sampleCount;
  final double calibrationSlope;
  final int calibrationOffset;

  const SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrationSlope,
    required this.calibrationOffset,
  });

  /// Get peak raw value for a given channel.
  int peakRaw(int channel) {
    int peak = 0;
    final data = channels[channel];
    for (int i = 0; i < sampleCount; i++) {
      if (data[i] > peak) peak = data[i];
    }
    return peak;
  }

  /// Get average raw value for a given channel.
  double averageRaw(int channel) {
    double sum = 0;
    final data = channels[channel];
    for (int i = 0; i < sampleCount; i++) {
      sum += data[i];
    }
    return sum / sampleCount;
  }

  /// Duration in seconds.
  double get durationSeconds => sampleCount / sampleRate;
}
