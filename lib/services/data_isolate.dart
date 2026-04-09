import 'dart:typed_data';
import 'package:isolate_manager/isolate_manager.dart';

import 'bt_device_config.dart';

// Messages TO Isolate
abstract class DataIsolateRequest {
  Map<String, dynamic> toMap();

  static DataIsolateRequest fromMap(Map<String, dynamic> map) {
    switch (map['type']) {
      case 'InitRequest':
        return InitRequest(
          map['samplesPerSec'],
          map['maxDurationSeconds'],
          map['numChannels'],
        );
      case 'BlePacketRequest':
        return BlePacketRequest(map['data'] as Uint8List);
      case 'TareRequest':
        return TareRequest();
      case 'SetSessionRecordingStartRequest':
        return SetSessionRecordingStartRequest();
      case 'FetchSliceRequest':
        return FetchSliceRequest(
          startIdx: map['startIdx'],
          endIdx: map['endIdx'],
        );
      case 'RenderRequest':
        return RenderRequest(
          startTimeMs: map['startTimeMs'],
          endTimeMs: map['endTimeMs'],
          pixelWidth: map['pixelWidth'],
        );
      default:
        throw Exception('Unknown request type: ${map['type']}');
    }
  }
}

class InitRequest extends DataIsolateRequest {
  final int samplesPerSec;
  final int maxDurationSeconds;
  final int numChannels;

  InitRequest(this.samplesPerSec, this.maxDurationSeconds, this.numChannels);

  @override
  Map<String, dynamic> toMap() => {
    'type': 'InitRequest',
    'samplesPerSec': samplesPerSec,
    'maxDurationSeconds': maxDurationSeconds,
    'numChannels': numChannels,
  };
}

class BlePacketRequest extends DataIsolateRequest {
  final Uint8List data;
  BlePacketRequest(this.data);

  @override
  Map<String, dynamic> toMap() => {'type': 'BlePacketRequest', 'data': data};
}

class TareRequest extends DataIsolateRequest {
  @override
  Map<String, dynamic> toMap() => {'type': 'TareRequest'};
}

class SetSessionRecordingStartRequest extends DataIsolateRequest {
  @override
  Map<String, dynamic> toMap() => {'type': 'SetSessionRecordingStartRequest'};
}

class FetchSliceRequest extends DataIsolateRequest {
  final int startIdx;
  final int endIdx;

  FetchSliceRequest({required this.startIdx, required this.endIdx});

  @override
  Map<String, dynamic> toMap() => {
    'type': 'FetchSliceRequest',
    'startIdx': startIdx,
    'endIdx': endIdx,
  };
}

class RenderRequest extends DataIsolateRequest {
  final int startTimeMs;
  final int endTimeMs;
  final int pixelWidth;

  RenderRequest({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.pixelWidth,
  });

  @override
  Map<String, dynamic> toMap() => {
    'type': 'RenderRequest',
    'startTimeMs': startTimeMs,
    'endTimeMs': endTimeMs,
    'pixelWidth': pixelWidth,
  };
}

// Messages FROM Isolate
abstract class DataIsolateResponse {
  Map<String, dynamic> toMap();

  static DataIsolateResponse fromMap(Map<String, dynamic> map) {
    switch (map['type']) {
      case 'StatsUpdateResponse':
        return StatsUpdateResponse(
          rawSz: map['rawSz'],
          currentRaw: map['currentRaw'] as Int32List,
          peakRaw: map['peakRaw'] as Int32List,
          tare: map['tare'] as Float64List,
          recordingStartIdx: map['recordingStartIdx'],
        );
      case 'RenderBatchResponse':
        return RenderBatchResponse(
          List<Float32List>.from(map['linesMinMax']),
          map['pointCount'] as int,
        );
      case 'SliceResultResponse':
        return SliceResultResponse(List<Int32List>.from(map['channelsData']));
      default:
        throw Exception('Unknown response type: ${map['type']}');
    }
  }
}

class StatsUpdateResponse extends DataIsolateResponse {
  final int rawSz;
  final Int32List currentRaw;
  final Int32List peakRaw;
  final Float64List tare;
  final int recordingStartIdx;

  StatsUpdateResponse({
    required this.rawSz,
    required this.currentRaw,
    required this.peakRaw,
    required this.tare,
    required this.recordingStartIdx,
  });

  @override
  Map<String, dynamic> toMap() => {
    'type': 'StatsUpdateResponse',
    'rawSz': rawSz,
    'currentRaw': currentRaw,
    'peakRaw': peakRaw,
    'tare': tare,
    'recordingStartIdx': recordingStartIdx,
  };
}

/// Batched render result containing min/max data for ALL lines in one response.
class RenderBatchResponse extends DataIsolateResponse {
  /// One Float32List per line, each containing [min0, max0, min1, max1, ...].
  final List<Float32List> linesMinMax;
  final int pointCount;

  RenderBatchResponse(this.linesMinMax, this.pointCount);

  @override
  Map<String, dynamic> toMap() => {
    'type': 'RenderBatchResponse',
    'linesMinMax': linesMinMax,
    'pointCount': pointCount,
  };
}

class SliceResultResponse extends DataIsolateResponse {
  final List<Int32List> channelsData;
  SliceResultResponse(this.channelsData);

  @override
  Map<String, dynamic> toMap() => {
    'type': 'SliceResultResponse',
    'channelsData': channelsData,
  };
}

// ----------------------------------------------------------------------------
// The actual Isolate process
// ----------------------------------------------------------------------------

@pragma('vm:entry-point')
@isolateManagerCustomWorker
void dataIsolateWorker(dynamic params) {
  _DataProcessor? processor;

  IsolateManagerFunction.customFunction<
    Map<String, dynamic>,
    Map<String, dynamic>
  >(
    params,
    onEvent: (controller, messageMap) {
      if (messageMap.isEmpty) return <String, dynamic>{};

      final message = DataIsolateRequest.fromMap(messageMap);

      if (message is InitRequest) {
        processor = _DataProcessor(
          samplesPerSec: message.samplesPerSec,
          maxDurationSeconds: message.maxDurationSeconds,
          numChannels: message.numChannels,
        );
        return <String, dynamic>{};
      } else if (message is BlePacketRequest) {
        return processor?.processBlePacket(message.data) ?? <String, dynamic>{};
      } else if (message is TareRequest) {
        processor?.requestTare();
        return <String, dynamic>{};
      } else if (message is SetSessionRecordingStartRequest) {
        processor?.setRecordingStart();
        return <String, dynamic>{};
      } else if (message is RenderRequest) {
        return processor?.handleRenderRequest(message) ?? <String, dynamic>{};
      } else if (message is FetchSliceRequest) {
        return processor?.handleFetchSlice(message) ?? <String, dynamic>{};
      }

      return <String, dynamic>{};
    },
    onInit: (controller) {
      // Nothing needed on init
    },
    autoHandleException: false,
  );
}

class _DataProcessor {
  final int samplesPerSec;
  final int numChannels;
  final int capacity; // max samples in circular buffer

  // Layers for decimation
  late final List<Float32List> _layer1x; // size: capacity

  // Tracking bounds per decimation layer per channel.
  late final List<Float32List> _min64x;
  late final List<Float32List> _max64x;
  late final List<Float32List> _min4096x;
  late final List<Float32List> _max4096x;

  int _head = 0; // write head index
  int _totalWritten =
      0; // Total samples written ever (used to know logical time)

  // Taring logic
  static const int _tareWindow = 1024;
  int _tareCount = _tareWindow;
  late final Float64List _runningTotalTare;
  late final Float64List _tare;

  late final Int32List _currentRaw;
  late final Int32List _peakRaw;
  int _recordingStartIdx = 0;

  _DataProcessor({
    required this.samplesPerSec,
    required int maxDurationSeconds,
    required this.numChannels,
  }) : capacity = _alignCapacity(samplesPerSec * maxDurationSeconds) {
    _layer1x = List.generate(numChannels, (_) => Float32List(capacity));

    final cap64 = capacity ~/ 64;
    _min64x = List.generate(numChannels, (_) => Float32List(cap64));
    _max64x = List.generate(numChannels, (_) => Float32List(cap64));

    final cap4096 = capacity ~/ 4096;
    _min4096x = List.generate(numChannels, (_) => Float32List(cap4096));
    _max4096x = List.generate(numChannels, (_) => Float32List(cap4096));

    _runningTotalTare = Float64List(numChannels);
    _tare = Float64List(numChannels);
    _currentRaw = Int32List(numChannels);
    _peakRaw = Int32List(numChannels);
  }

  static int _alignCapacity(int cap) {
    final int rem = cap % 4096;
    if (rem == 0) return cap;
    return cap + (4096 - rem);
  }

  void requestTare() {
    _tareCount = _tareWindow;
    for (int i = 0; i < numChannels; ++i) {
      _tare[i] = 0;
      _runningTotalTare[i] = 0;
    }
  }

  void setRecordingStart() {
    _recordingStartIdx = _totalWritten;
  }

  bool get taring => (_tareCount > 0);

  // Helper method mapping ADC chan to graph line. We assume we track 2 lines.
  int _chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1;
  }

  /// Process a BLE packet and return a StatsUpdateResponse map (always).
  Map<String, dynamic> processBlePacket(Uint8List data) {
    if (data.isEmpty) {
      return _buildStatsMap();
    }

    if (data.length < nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength) {
      return _buildStatsMap();
    }

    for (
      int packetStart = nwHeaderSize;
      packetStart < nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength;
      packetStart += nwAdcSampleLength
    ) {
      for (int i = 0; i < nwNumAdcChan; ++i) {
        final int baseIndex = packetStart + i * 3;
        final int res =
            ((data[baseIndex] << 0) |
                    (data[baseIndex + 1] << 8) |
                    (data[baseIndex + 2] << 16))
                .toSigned(24);

        final int idx = _chanToLine(i);
        if (idx >= 0 && idx < numChannels) {
          _currentRaw[idx] = res;

          if (taring) {
            _runningTotalTare[idx] += res;
          } else {
            if (res > _peakRaw[idx]) _peakRaw[idx] = res;

            final val = res.toDouble();
            _layer1x[idx][_head] = val;

            final int idx64 = _head ~/ 64;
            if (_head % 64 == 0) {
              _min64x[idx][idx64] = val;
              _max64x[idx][idx64] = val;
            } else {
              if (val < _min64x[idx][idx64]) _min64x[idx][idx64] = val;
              if (val > _max64x[idx][idx64]) _max64x[idx][idx64] = val;
            }

            final int idx4096 = _head ~/ 4096;
            if (_head % 4096 == 0) {
              _min4096x[idx][idx4096] = val;
              _max4096x[idx][idx4096] = val;
            } else {
              if (val < _min4096x[idx][idx4096]) _min4096x[idx][idx4096] = val;
              if (val > _max4096x[idx][idx4096]) _max4096x[idx][idx4096] = val;
            }
          }
        }
      }

      if (taring) {
        _tareCount--;
        if (!taring) {
          for (int i = 0; i < numChannels; ++i) {
            _tare[i] = _runningTotalTare[i] / _tareWindow;
            _runningTotalTare[i] = 0;
          }
        }
      } else {
        _head = (_head + 1) % capacity;
        _totalWritten++;
      }
    }

    return _buildStatsMap();
  }

  Map<String, dynamic> _buildStatsMap() {
    return StatsUpdateResponse(
      rawSz: _totalWritten,
      currentRaw: Int32List.fromList(_currentRaw),
      peakRaw: Int32List.fromList(_peakRaw),
      tare: Float64List.fromList(_tare),
      recordingStartIdx: _recordingStartIdx,
    ).toMap();
  }

  Map<String, dynamic> handleFetchSlice(FetchSliceRequest req) {
    int start = req.startIdx;
    int end = req.endIdx;
    if (start < 0) start = 0;
    if (end > _totalWritten) end = _totalWritten;
    if (start > end) {
      return SliceResultResponse([]).toMap();
    }

    final len = end - start;
    final list = List.generate(numChannels, (_) => Int32List(len));

    for (int i = 0; i < numChannels; i++) {
      for (int k = 0; k < len; k++) {
        final int logicalIdx = start + k;
        if (logicalIdx < _totalWritten - capacity) {
          list[i][k] = 0;
        } else {
          final int physicalIdx = logicalIdx % capacity;
          list[i][k] = _layer1x[i][physicalIdx].toInt();
        }
      }
    }

    return SliceResultResponse(list).toMap();
  }

  Map<String, dynamic> handleRenderRequest(RenderRequest req) {
    final startTimeS = req.startTimeMs / 1000.0;
    final endTimeS = req.endTimeMs / 1000.0;
    int startIdx = (startTimeS * samplesPerSec).floor();
    int endIdx = (endTimeS * samplesPerSec).ceil();

    if (startIdx < _totalWritten - capacity) {
      startIdx = _totalWritten - capacity;
    }
    if (startIdx < 0) startIdx = 0;
    if (endIdx > _totalWritten) endIdx = _totalWritten;

    if (startIdx >= endIdx || req.pixelWidth <= 0) {
      return RenderBatchResponse(
        List.generate(numChannels, (_) => Float32List(0)),
        0,
      ).toMap();
    }

    final int points = req.pixelWidth;
    final double samplesPerPixel = (endIdx - startIdx) / points;
    final List<Float32List> allLines = [];

    for (int line = 0; line < numChannels; line++) {
      final outMinMax = Float32List(points * 2);

      for (int p = 0; p < points; p++) {
        final double bucketStartIdx = startIdx + p * samplesPerPixel;
        final double bucketEndIdx = startIdx + (p + 1) * samplesPerPixel;

        int bStart = bucketStartIdx.floor();
        int bEnd = bucketEndIdx.floor();
        if (bStart == bEnd) bEnd++;

        double minV = double.maxFinite;
        double maxV = -double.maxFinite;

        int current = bStart;
        while (current < bEnd) {
          final int remaining = bEnd - current;
          final int physicalIdx = current % capacity;

          if (remaining >= 4096 && physicalIdx % 4096 == 0) {
            final int p4096 = physicalIdx ~/ 4096;
            final double cMin = _min4096x[line][p4096];
            final double cMax = _max4096x[line][p4096];
            if (cMin < minV) minV = cMin;
            if (cMax > maxV) maxV = cMax;
            current += 4096;
          } else if (remaining >= 64 && physicalIdx % 64 == 0) {
            final int p64 = physicalIdx ~/ 64;
            final double cMin = _min64x[line][p64];
            final double cMax = _max64x[line][p64];
            if (cMin < minV) minV = cMin;
            if (cMax > maxV) maxV = cMax;
            current += 64;
          } else {
            final double v = _layer1x[line][physicalIdx];
            if (v < minV) minV = v;
            if (v > maxV) maxV = v;
            current++;
          }
        }

        if (minV == double.maxFinite) minV = 0;
        if (maxV == -double.maxFinite) maxV = 0;

        outMinMax[p * 2] = minV;
        outMinMax[p * 2 + 1] = maxV;
      }

      allLines.add(outMinMax);
    }

    return RenderBatchResponse(allLines, points).toMap();
  }
}
