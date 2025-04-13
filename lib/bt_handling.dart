import 'dart:async';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

// ignore: unused_import
import 'mockble.dart';

// const btDeviceUUID = "E4:B0:63:81:5B:19";
const btGattId = "a659ee73-460b-45d5-8e63-ab6bf0825942";
const btServiceId = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
const btChrAdcFeedId = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const btChrCalibration = "10adce11-68a6-450b-9810-ca11b39fd283";

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

  BluetoothHandling() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;

    unawaited(_updateBluetoothState());
  }

  void initializeBluetooth(
      OnValueChange onValueChangeCb,
      void Function(Uint8List data) onUpdateCalibration,
      void Function() onStateChange) {
    _notifyCalibrationUpdated = onUpdateCalibration;
    _notifyStateChanged = onStateChange;

    UniversalBle.onValueChange = onValueChangeCb;
  }

  void dispose() {
    UniversalBle.onValueChange = null;

    _notifyCalibrationUpdated = (_) {};
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
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  void _onConnectionChange(
      String deviceId, bool isConnected, String? err) async {
    debugPrint('isConnected $deviceId, $isConnected');
    if (isConnected) {
      _selectedDeviceId = deviceId;
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
}
