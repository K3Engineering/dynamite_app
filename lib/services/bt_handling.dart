import 'dart:async';
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
    _notifyStateChanged();
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
    _notifyStateChanged();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    _notifyStateChanged();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    await disconnectSelectedDevice();
    _devices.clear();
    _services.clear();
    if (_isSubscribed) {
      return;
    }
    _isScanning = true;
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [btServiceId]),
      platformConfig: PlatformConfig(
        web: WebOptions(optionalServices: [btServiceId]),
      ),
    );
    _notifyStateChanged();
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
      // Starting a recording: mark the current buffer position.
      dataHub._recordingStartIdx = dataHub.rawSz;
    }
    _sessionInProgress = !_sessionInProgress;
    dataHub._prevSampleCount = -1;
    _notifyStateChanged();
  }

  void stopSession() {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      dataHub._prevSampleCount = -1;
      _notifyStateChanged();
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
    _notifyStateChanged();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await _stopScan();
    }
    if (_selectedDeviceId.isEmpty) {
      await UniversalBle.connect(deviceId);
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
        _notifyStateChanged();
        return;
      }
    }
  }

  void _notifyStateChanged() {
    notifyListeners();
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
  static const int numGraphLines = 2;
  static const int numAdcChannels = 4;
  static const int _tareWindow = 1024;
  static const double _defaultSlope = 0.0001117587;
  static const int samplesPerSec = 1000;
  static const int _maxDataSz = samplesPerSec * 60 * 10;
  final Float64List tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  final Int32List rawMax = Int32List(numGraphLines);
  final Int32List rawMin = Int32List(numGraphLines);

  /// Latest raw value per graph line (for live stats display).
  final Int32List _currentRaw = Int32List(numGraphLines);

  final List<Int32List> rawData = List.generate(
    DataHub.numGraphLines,
    (_) => Int32List(_maxDataSz),
    growable: false,
  );
  int _tareCount = _tareWindow;
  int rawSz = 0;
  int _prevSampleCount = -1;
  DeviceCalibration deviceCalibration = DeviceCalibration(0, _defaultSlope);

  /// Index into rawData where the current recording started.
  /// Used by SessionStorage to know which slice to save.
  int _recordingStartIdx = 0;
  int get recordingStartIdx => _recordingStartIdx;

  void clear() {
    _tareCount = _tareWindow;
    rawSz = 0;
    _recordingStartIdx = 0;
    for (int i = 0; i < numGraphLines; ++i) {
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
    for (int i = 0; i < numGraphLines; ++i) {
      tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  /// Map ADC channel index (0-3) to graph line index (0-1).
  /// Returns -1 if channel has no graph line.
  static int chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1;
  }

  /// Get current force for a given ADC channel in the specified unit.
  double currentForce(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0) return 0;
    final rawTared = _currentRaw[lineIdx] - tare[lineIdx];
    final kgf = rawTared * deviceCalibration.slope;
    return unit.fromKgf(kgf);
  }

  /// Get peak force for a given ADC channel in the specified unit.
  double peakForce(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0) return 0;
    final rawTared = rawMax[lineIdx] - tare[lineIdx];
    final kgf = rawTared * deviceCalibration.slope;
    return unit.fromKgf(kgf);
  }

  /// Get minimum (most negative) force for a given ADC channel in the specified unit.
  double minForce(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0) return 0;
    final rawTared = rawMin[lineIdx] - tare[lineIdx];
    final kgf = rawTared * deviceCalibration.slope;
    return unit.fromKgf(kgf);
  }

  /// Get the instantaneous derivative (first-difference) for a channel in unit/s.
  double currentDerivative(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0 || rawSz < 2) return 0;
    final diff = rawData[lineIdx][rawSz - 1] - rawData[lineIdx][rawSz - 2];
    final kgfPerSec = diff * deviceCalibration.slope * samplesPerSec;
    return unit.fromKgf(kgfPerSec);
  }

  void _addTare(int val, int idx) {
    _runningTotal[idx] += val;
  }

  void _addData(int val, int idx) {
    rawData[idx][rawSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
    if (val < rawMin[idx]) {
      rawMin[idx] = val;
    }
  }

  void _updateCalibration(Uint8List data) {
    // TODO: implement calibration parsing
    deviceCalibration = DeviceCalibration(0, _defaultSlope);
    debugPrint(
      'Calibration ${deviceCalibration.slope}, offset ${deviceCalibration.offset}',
    );
  }

  void _notifyDataReceived() {
    notifyListeners();
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

        final int idx = chanToLine(i);
        if (idx >= 0) {
          _currentRaw[idx] = res;
          if (taring) {
            _addTare(res, idx);
          } else {
            // Always buffer data for live display.
            _addData(res, idx);
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
        rawSz++;
        if (rawSz >= _maxDataSz) {
          break;
        }
      }
    }

    _notifyDataReceived();
    return rawSz < _maxDataSz;
  }
}

class DeviceCalibration {
  DeviceCalibration(this.offset, this.slope);
  final int offset;
  final double slope;
}
