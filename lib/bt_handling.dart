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
const btS2 = "00001800-0000-1000-8000-00805f9b34fb";
const btS3 = "00001801-0000-1000-8000-00805f9b34fb";

class BluetoothHandling {
  AvailabilityState bluetoothState = AvailabilityState.unknown;
  final List<BleDevice> devices = [];
  bool isScanning = false;
  String selectedDeviceId = '';
  bool isSubscribed = false;
  final List<BleService> services = [];
  late final void Function(Uint8List) notifyCalibrationUpdated;
  late final void Function() notifyStateChanged;

  void initializeBluetooth(OnValueChange onValueChangeCb) {
    //UniversalBle.setInstance(MockBlePlatform.instance);

    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onValueChange = onValueChangeCb;
    unawaited(_updateBluetoothState());
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth(); // this isn't implemented on web
    }
    bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
  }

  void _onScanResult(BleDevice newDevice) {
    for (var dev in devices) {
      if (dev.deviceId == newDevice.deviceId) {
        if ((dev.name == null) && (newDevice.name != null)) {
          dev = newDevice;
        }
        return;
      }
    }
    devices.add(newDevice);
    notifyStateChanged();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    bluetoothState = state;
  }

  Future<void> stopScan() async {
    assert(!isSubscribed);
    await UniversalBle.stopScan();
    isScanning = false;
    notifyStateChanged();
  }

  Future<void> startScan() async {
    if (bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    await disconnectSelectedDevice();
    devices.clear();
    services.clear();
    assert(!isSubscribed);
    isScanning = true;
    await UniversalBle.startScan(
      platformConfig: PlatformConfig(
        web: WebOptions(
            optionalServices: [btServiceId, btChrAdcFeedId, btS2, btS3]),
      ),
    );
    notifyStateChanged();
  }

  Future<void> toggleScan() async {
    if (isScanning) {
      await stopScan();
    } else {
      await startScan();
    }
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  void _onConnectionChange(
      String deviceId, bool isConnected, String? err) async {
    debugPrint('isConnected $deviceId, $isConnected');
    if (isConnected) {
      selectedDeviceId = deviceId;
      services.addAll(await UniversalBle.discoverServices(deviceId));
    } else {
      isSubscribed = false;
      selectedDeviceId = '';
      services.clear();
    }
    notifyStateChanged();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (isScanning) {
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
    await UniversalBle.disconnect(selectedDeviceId);
    await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle
  }

  void dispose() {
    UniversalBle.onScanResult = null;
    UniversalBle.onAvailabilityChange = null;
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    if (selectedDeviceId.isEmpty) {
      return;
    }
    for (var characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        notifyCalibrationUpdated(await UniversalBle.readValue(
            selectedDeviceId, service.uuid, btChrCalibration));
        await UniversalBle.setNotifiable(selectedDeviceId, service.uuid,
            characteristic.uuid, BleInputProperty.notification);
        isSubscribed = true;
        notifyStateChanged();
        return;
      }
    }
  }
}
