import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import "bt_device_config.dart";
// ignore: unused_import
import 'mockble.dart';

class BluetoothHandling {
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

  bool _isSubscribed = false;
  bool get isSubscribed => _isSubscribed;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  void Function(Uint8List) _notifyCalibrationUpdated = (_) {};
  void Function() _notifyStateChanged = () {};
  void Function() _notifyDataReceived = () {};

  final DataHub dataHub = DataHub();

  BluetoothHandling() {
    if (useMockBt) {
      UniversalBle.setInstance(MockBlePlatform.instance);
    }
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;

    unawaited(_updateBluetoothState());
  }

  void setListener(
      void Function() onStateChange, void Function() onDataReceived) {
    _notifyCalibrationUpdated = dataHub._onUpdateCalibration;
    _notifyStateChanged = onStateChange;
    _notifyDataReceived = onDataReceived;

    UniversalBle.onValueChange = _processReceivedData;
  }

  void resetListener() {
    UniversalBle.onValueChange = null;

    _notifyCalibrationUpdated = (_) {};
    _notifyDataReceived = () {};
    _notifyStateChanged = () {};
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth(); // this isn't implemented on web
    }
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    _notifyStateChanged();
  }

  void _onScanResult(BleDevice newDevice) {
    if (devices.isEmpty) {
      _devices.add(newDevice);
    } else if (newDevice.rssi != null) {
      if ((_devices[0].rssi == null) || (newDevice.rssi! > _devices[0].rssi!)) {
        _devices[0] = newDevice;
      }
    }
    _notifyStateChanged();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
  }

  Future<void> stopScan() async {
    assert(!_isSubscribed);
    await UniversalBle.stopScan();
    _isScanning = false;
    _notifyStateChanged();
  }

  Future<void> startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    await disconnectSelectedDevice();
    _devices.clear();
    _services.clear();
    assert(!_isSubscribed);
    _isScanning = true;
    await UniversalBle.startScan(
      scanFilter: ScanFilter(
        withServices: [btServiceId],
      ),
      platformConfig: PlatformConfig(
        web: WebOptions(
          optionalServices: [btServiceId],
        ),
      ),
    );
    _notifyStateChanged();
  }

  Future<void> toggleScan() async {
    if (_isScanning) {
      await stopScan();
    } else {
      await startScan();
    }
  }

  void toggleSession() {
    assert(selectedDeviceId.isNotEmpty);
    _sessionInProgress = !_sessionInProgress;
    _notifyStateChanged();
  }

  void stopSession() {
    _sessionInProgress = false;
    _notifyStateChanged();
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  void _onConnectionChange(
      String deviceId, bool isConnected, String? err) async {
    debugPrint('isConnected $deviceId, $isConnected');
    if (isConnected) {
      _selectedDeviceId = deviceId;

      debugPrint('Requested MTU change');
      int mtu = await UniversalBle.requestMtu(deviceId, 247);
      debugPrint('MTU set to: ${mtu}');
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
      _services.clear();
      _sessionInProgress = false;
    }
    _notifyStateChanged();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await stopScan();
    }
    try {
      await disconnectSelectedDevice();
      await UniversalBle.connect(deviceId);
    } catch (e) {
      debugPrint('connect $deviceId err: $e');
    }
  }

  Future<void> disconnectSelectedDevice() async {
    if (selectedDeviceId.isEmpty) {
      return;
    }
    await UniversalBle.disconnect(_selectedDeviceId);
    await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    if (_selectedDeviceId.isEmpty) {
      return;
    }
    for (final characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        _notifyCalibrationUpdated(await UniversalBle.readValue(
            _selectedDeviceId, service.uuid, btChrCalibration));
        await UniversalBle.setNotifiable(_selectedDeviceId, service.uuid,
            characteristic.uuid, BleInputProperty.notification);
        _isSubscribed = true;
        _notifyStateChanged();
        return;
      }
    }
  }

  void _processReceivedData(String _, String __, Uint8List data) {
    if (!sessionInProgress) return;

    final canContinue = dataHub._parseDataPacket(data);
    if (!canContinue) {
      stopSession();
    }
    _notifyDataReceived();
  }
}

class DataHub {
  static const int numGraphLines = 2;
  static const int _tareWindow = 1024;
  static const double _defaultSlope = 0.0001117587;
  static const int samplesPerSec = 1000;
  static const int _maxDataSz = samplesPerSec * 60 * 10;
  final Float64List tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  final Int32List rawMax = Int32List(numGraphLines);
  final List<Int32List> rawData = List.generate(
    DataHub.numGraphLines,
    (_) => Int32List(_maxDataSz),
    growable: false,
  );
  int _timeTick = 0;
  int rawSz = 0;
  DeviceCalibration deviceCalibration = DeviceCalibration(0, _defaultSlope);

  void clear() {
    _timeTick = 0;
    for (int i = 0; i < numGraphLines; ++i) {
      rawSz = 0;
      rawMax[i] = 0;
      tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  bool get taring => (_timeTick > 0) && (_timeTick <= _tareWindow);

  bool _addTare(int val, int idx) {
    if (_timeTick > _tareWindow) {
      return false;
    }
    _runningTotal[idx] += val;
    if (_timeTick == _tareWindow) {
      tare[idx] = _runningTotal[idx] / _tareWindow;
      _runningTotal[idx] = 0;
    }
    return true;
  }

  void _addData(int val, int idx) {
    rawData[idx][rawSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
  }

  void _onUpdateCalibration(Uint8List data) {
    // TODO: implement calibration parsing
    deviceCalibration = DeviceCalibration(0, _defaultSlope);
    debugPrint(
        'Calibration ${deviceCalibration.slope}, offset ${deviceCalibration.offset}');
  }

  static int _chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1; // No graph line for this chanel
  }

  bool _parseDataPacket(Uint8List data) {
    if (data.isEmpty) {
      debugPrint("data isEmpty");
      return false;
    }
    if (data.length % adcSampleLength != 0) {
      debugPrint('Incorrect buffer size received');
      debugPrint('Expected mod ${adcSampleLength}, got ${data.length}');
      return false;
    }

    for (int packetStart = 0;
        packetStart < data.length;
        packetStart += adcSampleLength) {
      assert(packetStart + adcSampleLength <= data.length);
      // final status = (data[packetStart + 1] << 8) | data[packetStart];
      // final crc = data[packetStart + 14];
      _timeTick++;
      const int numAdcChan = 4;
      for (int i = 0; i < numAdcChan; ++i) {
        final int baseIndex = packetStart + 2 + i * 3;
        final int res = ((data[baseIndex] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex + 2])
            .toSigned(24);

        final int idx = _chanToLine(i);
        if (idx >= 0) {
          if (!_addTare(res, idx)) {
            _addData(res, idx);
          }
        }
      }
      if (_timeTick > _tareWindow) {
        rawSz++;
      }
    }
    return rawSz < _maxDataSz;
  }
}

class DeviceCalibration {
  DeviceCalibration(this.offset, this.slope);
  final int offset;
  final double slope;
}
