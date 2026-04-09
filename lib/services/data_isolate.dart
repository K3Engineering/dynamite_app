import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'bt_device_config.dart';

// Messages TO Isolate
abstract class DataIsolateRequest {}

class InitRequest extends DataIsolateRequest {
  final int samplesPerSec;
  final int maxDurationSeconds;
  final int numChannels;

  InitRequest(this.samplesPerSec, this.maxDurationSeconds, this.numChannels);
}

class BlePacketRequest extends DataIsolateRequest {
  final Uint8List data;
  BlePacketRequest(this.data);
}

class TareRequest extends DataIsolateRequest {}

class SetSessionRecordingStartRequest extends DataIsolateRequest {}

class FetchSliceRequest extends DataIsolateRequest {
  final int startIdx;
  final int endIdx;
  final SendPort replyPort;

  FetchSliceRequest({
    required this.startIdx,
    required this.endIdx,
    required this.replyPort,
  });
}

class RenderRequest extends DataIsolateRequest {
  final int startTimeMs; // start time in milliseconds from 0
  final int endTimeMs;
  final int pixelWidth;
  final SendPort replyPort;

  RenderRequest({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.pixelWidth,
    required this.replyPort,
  });
}

// Messages FROM Isolate
abstract class DataIsolateResponse {}

class StatsUpdateResponse extends DataIsolateResponse {
  final int rawSz;
  final Int32List currentRaw; // one per channel
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
}

class RenderResultResponse extends DataIsolateResponse {
  final int lineIdx;
  final TransferableTypedData
  minMaxData; // packed [min, max, min, max, ...] per pixel
  final int pointCount;

  RenderResultResponse({
    required this.lineIdx,
    required this.minMaxData,
    required this.pointCount,
  });
}

class SliceResultResponse extends DataIsolateResponse {
  final List<Int32List> channelsData;
  SliceResultResponse(this.channelsData);
}

// ----------------------------------------------------------------------------
// The actual Isolate process
// ----------------------------------------------------------------------------

void dataIsolateEntryPoint(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  _DataProcessor? processor;

  receivePort.listen((message) {
    if (message is InitRequest) {
      processor = _DataProcessor(
        mainSendPort: mainSendPort,
        samplesPerSec: message.samplesPerSec,
        maxDurationSeconds: message.maxDurationSeconds,
        numChannels: message.numChannels,
      );
    } else if (message is BlePacketRequest) {
      processor?.processBlePacket(message.data);
    } else if (message is TareRequest) {
      processor?.requestTare();
    } else if (message is SetSessionRecordingStartRequest) {
      processor?.setRecordingStart();
    } else if (message is RenderRequest) {
      processor?.handleRenderRequest(message);
    } else if (message is FetchSliceRequest) {
      processor?.handleFetchSlice(message);
    }
  });
}

class _DataProcessor {
  final SendPort mainSendPort;
  final int samplesPerSec;
  final int numChannels;
  final int capacity; // max samples in circular buffer

  // Layers for decimation
  late final List<Float32List> _layer1x; // size: capacity

  // Tracking bounds per decimation layer per channel.
  // For 64x layer, each element stores [min, max] = 2 floats.
  // Actually, wait, simpler: separate Float32Lists for Min and Max.
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

  DateTime? _lastStatsSent;

  _DataProcessor({
    required this.mainSendPort,
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
    int rem = cap % 4096;
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

  void processBlePacket(Uint8List data) {
    if (data.isEmpty) return;

    // Ignore packet sequence count for now

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

            // Write to layer 1x
            final val = res.toDouble();
            _layer1x[idx][_head] = val;

            // Update 64x layer
            final int idx64 = _head ~/ 64;
            if (_head % 64 == 0) {
              _min64x[idx][idx64] = val;
              _max64x[idx][idx64] = val;
            } else {
              if (val < _min64x[idx][idx64]) _min64x[idx][idx64] = val;
              if (val > _max64x[idx][idx64]) _max64x[idx][idx64] = val;
            }

            // Update 4096x layer
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

    // Throttle stats updates to ~60Hz
    final now = DateTime.now();
    if (_lastStatsSent == null ||
        now.difference(_lastStatsSent!).inMilliseconds > 16) {
      _lastStatsSent = now;
      mainSendPort.send(
        StatsUpdateResponse(
          rawSz: _totalWritten,
          currentRaw: Int32List.fromList(_currentRaw),
          peakRaw: Int32List.fromList(_peakRaw),
          tare: Float64List.fromList(_tare),
          recordingStartIdx: _recordingStartIdx,
        ),
      );
    }
  }

  void handleFetchSlice(FetchSliceRequest req) {
    // Only fetch what is available
    int start = req.startIdx;
    int end = req.endIdx;
    if (start < 0) start = 0;
    if (end > _totalWritten) end = _totalWritten;
    if (start > end) {
      req.replyPort.send(SliceResultResponse([]));
      return;
    }

    // Extract raw samples from circular buffer
    final len = end - start;
    final list = List.generate(numChannels, (_) => Int32List(len));

    for (int i = 0; i < numChannels; i++) {
      for (int k = 0; k < len; k++) {
        int logicalIdx = start + k;
        if (logicalIdx < _totalWritten - capacity) {
          // Lost data, fill with 0
          list[i][k] = 0;
        } else {
          int physicalIdx = logicalIdx % capacity;
          list[i][k] = _layer1x[i][physicalIdx].toInt();
        }
      }
    }

    req.replyPort.send(SliceResultResponse(list));
  }

  void handleRenderRequest(RenderRequest req) {
    final startTimeS = req.startTimeMs / 1000.0;
    final endTimeS = req.endTimeMs / 1000.0;
    int startIdx = (startTimeS * samplesPerSec).floor();
    int endIdx = (endTimeS * samplesPerSec).ceil();

    // Clamp to available data
    if (startIdx < _totalWritten - capacity)
      startIdx = _totalWritten - capacity;
    if (startIdx < 0) startIdx = 0;
    if (endIdx > _totalWritten) endIdx = _totalWritten;

    if (startIdx >= endIdx || req.pixelWidth <= 0) {
      for (int line = 0; line < numChannels; line++) {
        req.replyPort.send(
          RenderResultResponse(
            lineIdx: line,
            minMaxData: TransferableTypedData.fromList([Float32List(0)]),
            pointCount: 0,
          ),
        );
      }
      return;
    }

    final int points = req.pixelWidth;
    final double samplesPerPixel = (endIdx - startIdx) / points;

    for (int line = 0; line < numChannels; line++) {
      final outMinMax = Float32List(points * 2);

      for (int p = 0; p < points; p++) {
        final double bucketStartIdx = startIdx + p * samplesPerPixel;
        final double bucketEndIdx = startIdx + (p + 1) * samplesPerPixel;

        int bStart = bucketStartIdx.floor();
        int bEnd = bucketEndIdx.floor();
        if (bStart == bEnd) bEnd++; // ensure at least 1 sample

        double minV = double.maxFinite;
        double maxV = -double.maxFinite;

        int current = bStart;
        while (current < bEnd) {
          int remaining = bEnd - current;
          int physicalIdx = current % capacity;

          // Can we use 4096x layer?
          if (remaining >= 4096 && physicalIdx % 4096 == 0) {
            int p4096 = physicalIdx ~/ 4096;
            double cMin = _min4096x[line][p4096];
            double cMax = _max4096x[line][p4096];
            if (cMin < minV) minV = cMin;
            if (cMax > maxV) maxV = cMax;
            current += 4096;
          }
          // Can we use 64x layer?
          else if (remaining >= 64 && physicalIdx % 64 == 0) {
            int p64 = physicalIdx ~/ 64;
            double cMin = _min64x[line][p64];
            double cMax = _max64x[line][p64];
            if (cMin < minV) minV = cMin;
            if (cMax > maxV) maxV = cMax;
            current += 64;
          }
          // Use 1x layer
          else {
            double v = _layer1x[line][physicalIdx];
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

      req.replyPort.send(
        RenderResultResponse(
          lineIdx: line,
          minMaxData: TransferableTypedData.fromList([outMinMax]),
          pointCount: points,
        ),
      );
    }
  }
}
