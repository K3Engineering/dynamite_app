import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import 'bt_device_config.dart';
import '../models/force_unit.dart';
// ignore: unused_import
import 'mockble.dart';

class BluetoothHandling extends ChangeNotifier {
  AvailabilityState _bluetoothState = AvailabilityState.unknown;
  AvailabilityState get bluetoothState => _bluetoothState;

  final List<BleDevice> _devices = [];
  List<BleDevice> get devices => _devices;

  final List<BleService> _services = [];
  List<BleService> get services => _services;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// True between a connect request and the connection result (success or
  /// failure). Used purely for UI status; never assume the device is usable
  /// while this is true.
  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  String _selectedDeviceId = '';
  String get selectedDeviceId => _selectedDeviceId;

  /// Name of the currently connected device.
  String _connectedDeviceName = '';
  String get connectedDeviceName =>
      _connectedDeviceName.isEmpty ? _selectedDeviceId : _connectedDeviceName;

  bool _isSubscribed = false;
  bool get isSubscribed => _isSubscribed;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  final DataHub dataHub = DataHub();

  BluetoothHandling() {
    if (useMockBt) {
      UniversalBle.setInstance(MockBlePlatform.instance);
    }
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onValueChange = _processReceivedData;

    unawaited(_updateBluetoothState());
  }

  void stopProcessing() {
    UniversalBle.onValueChange = null;
    dataHub._prevSampleCount = -1;
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth();
    }
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    notifyListeners();
  }

  void _onScanResult(BleDevice newDevice) {
    // Keep all discovered devices (replace if same ID seen again with better RSSI).
    final existingIdx = _devices.indexWhere(
      (d) => d.deviceId == newDevice.deviceId,
    );
    if (existingIdx >= 0) {
      if (newDevice.rssi != null &&
          (_devices[existingIdx].rssi == null ||
              newDevice.rssi! > _devices[existingIdx].rssi!)) {
        _devices[existingIdx] = newDevice;
      }
    } else {
      _devices.add(newDevice);
    }
    notifyListeners();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    // Guard before any destructive clears: if we can't/shouldn't start a scan,
    // don't wipe the existing device list (which would leave the UI showing an
    // empty list with no picker having opened).
    if (_isSubscribed) {
      return;
    }
    await disconnectSelectedDevice();
    _devices.clear();
    _services.clear();
    _isScanning = true;
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [btServiceId]),
      platformConfig: PlatformConfig(
        web: WebOptions(optionalServices: [btServiceId]),
      ),
    );
    notifyListeners();
  }

  Future<void> toggleScan() async {
    if (_isScanning) {
      await _stopScan();
    } else {
      await _startScan();
    }
  }

  void toggleSession() {
    assert(_selectedDeviceId.isNotEmpty);
    if (!_sessionInProgress) {
      // Starting a recording: mark the current logical time.
      dataHub._recordingStartIdx = dataHub.totalSamples;
    }
    _sessionInProgress = !_sessionInProgress;
    dataHub._prevSampleCount = -1;
    notifyListeners();
  }

  void stopSession() {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      dataHub._prevSampleCount = -1;
      notifyListeners();
    }
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  void _onConnectionChange(
    String deviceId,
    bool isConnected,
    String? err,
  ) async {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    // The connect attempt has resolved (either connected or disconnected);
    // clear the transient UI flag regardless of outcome.
    _isConnecting = false;

    if (isConnected) {
      _selectedDeviceId = deviceId;

      // Store the device name
      final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
      _connectedDeviceName = device?.name ?? deviceId;

      if (!kIsWeb) {
        debugPrint('Requested MTU change');
        final int mtu = await UniversalBle.requestMtu(deviceId, 247);
        debugPrint('MTU set to: $mtu');
      }
      _services.addAll(await UniversalBle.discoverServices(deviceId));
      for (final srv in _services) {
        if (srv.uuid == btServiceId) {
          await subscribeToAdcFeed(srv);
          break;
        }
      }
    } else {
      _isSubscribed = false;
      _selectedDeviceId = '';
      _connectedDeviceName = '';
      _services.clear();
      _sessionInProgress = false;
    }
    notifyListeners();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await _stopScan();
    }
    if (_selectedDeviceId.isEmpty) {
      _isConnecting = true;
      notifyListeners();
      try {
        await UniversalBle.connect(deviceId);
      } catch (e) {
        // Connection result (success) arrives via _onConnectionChange; on a
        // failed connect attempt that callback may never fire, so clear the
        // transient flag here and let the caller surface the error.
        _isConnecting = false;
        notifyListeners();
        rethrow;
      }
    }
  }

  Future<void> disconnectSelectedDevice() async {
    if (_selectedDeviceId.isNotEmpty) {
      await UniversalBle.disconnect(_selectedDeviceId);
      await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle
    }
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    if (_selectedDeviceId.isEmpty) {
      return;
    }
    for (final characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        dataHub._updateCalibration(
          await UniversalBle.read(
            _selectedDeviceId,
            service.uuid,
            btChrCalibration,
          ),
        );
        await UniversalBle.subscribeNotifications(
          _selectedDeviceId,
          service.uuid,
          characteristic.uuid,
        );
        _isSubscribed = true;
        notifyListeners();
        return;
      }
    }
  }

  void _processReceivedData(String _, String _, Uint8List data, int? _) {
    // Always stream data to the DataHub for live display.
    final canContinue = dataHub._parseDataPacket(data);
    if (!canContinue) {
      stopSession();
    }
  }
}

class DataHub extends ChangeNotifier {
  /// Number of ADC channels the device streams. This is also the number of
  /// lines stored and displayed: channel index == storage index == display index.
  static const int numAdcChannels = nwNumAdcChan;
  static const int _tareWindow = 1024;
  static const int samplesPerSec = 1000;
  static const int maxDataSz = samplesPerSec * 60 * 10;
  final Float64List tare = Float64List(numAdcChannels);
  final Float64List _runningTotal = Float64List(numAdcChannels);
  final Int32List rawMax = Int32List(numAdcChannels);
  final Int32List rawMin = Int32List(numAdcChannels);

  /// Latest raw value per channel (for live stats display).
  final Int32List _currentRaw = Int32List(numAdcChannels);

  final List<Int32List> rawData = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(maxDataSz),
    growable: false,
  );
  int _tareCount = _tareWindow;
  int totalSamples = 0;
  int _prevSampleCount = -1;
  DeviceCalibration deviceCalibration = DeviceCalibration();

  /// Index into logical time where the current recording started.
  /// Used by SessionStorage to know which slice to save.
  int _recordingStartIdx = 0;
  int get recordingStartIdx => _recordingStartIdx;

  void clear() {
    _tareCount = _tareWindow;
    totalSamples = 0;
    _recordingStartIdx = 0;
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = 0;
      rawMin[i] = 0;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
    }
  }

  bool get taring => (_tareCount > 0);

  /// Request a new tare operation (zeros readings using next N samples).
  void requestTare() {
    _tareCount = _tareWindow;
    for (int i = 0; i < numAdcChannels; ++i) {
      tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  /// Get current force for a given ADC channel in the specified unit.
  double currentForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = _currentRaw[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get peak force for a given ADC channel in the specified unit.
  double peakForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMax[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get minimum (most negative) force for a given ADC channel in the specified unit.
  double minForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMin[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get the instantaneous derivative (first-difference) for a channel in unit/s.
  double currentDerivative(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples < 2) {
      return 0;
    }

    final diff = rawData[adcChannel][(totalSamples - 1) % maxDataSz] - rawData[adcChannel][(totalSamples - 2) % maxDataSz];
    // Derivative is raw diff per sample * samplesPerSec to get raw per sec
    return unit.fromRaw(diff.toDouble() * samplesPerSec, deviceCalibration.slope);
  }

  /// Get the AC RMS for a given ADC channel in the specified unit over the last 1 second window.
  double acRmsForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples == 0) {
      return 0;
    }

    final int count = math.min(samplesPerSec, totalSamples);
    final lineData = rawData[adcChannel];
    final startIdx = totalSamples - count;

    double sum = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      sum += lineData[i % maxDataSz];
    }
    final mean = sum / count;

    double sumSq = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      final diff = lineData[i % maxDataSz] - mean;
      sumSq += diff * diff;
    }
    final rmsRaw = math.sqrt(sumSq / count);

    return unit.fromRaw(rmsRaw, deviceCalibration.slope);
  }

  void injectTestData(int samples) {
    int added = 0;
    for (int i = 0; i < samples; i++) {
      final double phase = totalSamples * 2 * math.pi / samplesPerSec * 0.5;

      // Generate dummy waveforms for all channels so every line is exercised.
      // ch0: sine, ch1: cosine, ch2: half-amplitude sine, ch3: phase-shifted sine
      final values = <int>[
        (math.sin(phase) * 50000 + 50000).toInt(),
        (math.cos(phase) * 30000 + 30000).toInt(),
        (math.sin(phase) * 25000 + 25000).toInt(),
        (math.sin(phase + math.pi / 4) * 40000 + 40000).toInt(),
      ];

      for (int ch = 0; ch < numAdcChannels; ch++) {
        final val = values[ch];
        rawData[ch][totalSamples % maxDataSz] = val;
        _currentRaw[ch] = val;
        _addData(val, ch);
      }

      totalSamples++;
      added++;
    }

    if (added > 0) {
      notifyListeners();
    }
  }

  void _addTare(int val, int idx) {
    _runningTotal[idx] += val;
  }

  void _addData(int val, int idx) {
    rawData[idx][totalSamples % maxDataSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
    if (val < rawMin[idx]) {
      rawMin[idx] = val;
    }
  }

  void _updateCalibration(Uint8List data) {
    // TODO: implement calibration parsing
    deviceCalibration = DeviceCalibration();
    debugPrint(
      'Calibration ${deviceCalibration.slope}, offset ${deviceCalibration.offset}',
    );
  }

  /// Parse a BLE data packet.
  /// Data is always buffered for live display. Recording start/end is
  /// tracked via [_recordingStartIdx] set by BluetoothHandling.toggleSession().
  bool _parseDataPacket(Uint8List data) {
    if (data.isEmpty) {
      debugPrint("data isEmpty");
      return false;
    }

    final int count = data[0] + (data[1] << 8);
    if (_prevSampleCount != -1) {
      final int diff = (count - _prevSampleCount) & 0xFFFF;
      if (diff != 0) {
        debugPrint('# lost $diff samples');
        // TODO: signal lost packets
      }
    }
    _prevSampleCount = (count + nwAdcNumSamples) & 0xFFFF;

    for (
      int packetStart = nwHeaderSize;
      packetStart < nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength;
      packetStart += nwAdcSampleLength
    ) {
      assert(packetStart + nwAdcSampleLength <= data.length);
      for (int i = 0; i < nwNumAdcChan; ++i) {
        final int baseIndex = packetStart + i * 3;
        final int res =
            ((data[baseIndex] << 0) |
                    (data[baseIndex + 1] << 8) |
                    data[baseIndex + 2] << 16)
                .toSigned(24);

        // Channel index == storage line index.
        if (i < numAdcChannels) {
          _currentRaw[i] = res;
          if (taring) {
            _addTare(res, i);
          } else {
            // Always buffer data for live display.
            _addData(res, i);
          }
        }
      }

      if (taring) {
        _tareCount--;
        if (!taring) {
          for (int i = 0; i < _runningTotal.length; ++i) {
            tare[i] = _runningTotal[i] / _tareWindow;
            _runningTotal[i] = 0;
          }
        }
      } else {
        totalSamples++;
      }
    }

    notifyListeners();
    return true; // We never run out of space now
  }
}

class DeviceCalibration {
  DeviceCalibration({
    this.offset = 0,
    this.capacityKg = 200.0,
    this.sensitivityMvV = 2.0,
    this.excitationV = 4.5,
  });

  final int offset;
  final double capacityKg;
  final double sensitivityMvV;
  final double excitationV;

  /// Calculates kgf per raw count dynamically based on the parameters
  double get slope {
    final maxMv = sensitivityMvV * excitationV;
    return (capacityKg * ForceUnit.rawToMvMultiplier) / maxMv;
  }
}
