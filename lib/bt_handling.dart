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
  BleDevice? selectedDevice;
  final List<BleService> services = [];
  late final void Function(Uint8List) onNewDataCallback;
  late final void Function(Uint8List) onCalibrationCallback;
  late final void Function() onStateChange;

  void initializeBluetooth() {
    UniversalBle.setInstance(MockBlePlatform.instance);

    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onValueChange =
        (String deviceId, String characteristicId, Uint8List newData) {
      onNewDataCallback(newData);
    };
    unawaited(_updateBluetoothState());
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth(); // this isn't implemented on web
    }
    bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
  }

  void _onScanResult(BleDevice device) {
    for (var deviceListDevice in devices) {
      if (deviceListDevice.deviceId == device.deviceId) {
        if (deviceListDevice.name == device.name) {
          return;
        }
      }
    }
    devices.add(device);
    onStateChange();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    bluetoothState = state;
  }

  Future<void> stopScan() async {
    await UniversalBle.stopScan();
    isScanning = false;
    onStateChange();
  }

  Future<void> startScan() async {
    if (bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    await disconnectSelectedDevice();
    devices.clear();
    services.clear();
    isScanning = true;
    await UniversalBle.startScan(
      platformConfig: PlatformConfig(
        web: WebOptions(
            optionalServices: [btServiceId, btChrAdcFeedId, btS2, btS3]),
      ),
    );
    onStateChange();
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

  Future<void> connectToDevice(BleDevice device) async {
    if (isScanning) {
      await stopScan();
    }
    try {
      await disconnectSelectedDevice();
      await UniversalBle.connect(device.deviceId);
      selectedDevice = device;
      services.clear();
      services.addAll(await UniversalBle.discoverServices(device.deviceId));
    } catch (e) {
      // Error handling can be implemented here
    }
    onStateChange();
  }

  Future<void> disconnectSelectedDevice() async {
    final deviceId = selectedDevice?.deviceId;
    if (deviceId == null) {
      return;
    }

    await UniversalBle.disconnect(deviceId);
    selectedDevice = null;
    await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle
    onStateChange();
  }

  void dispose() {
    UniversalBle.onScanResult = null;
    UniversalBle.onAvailabilityChange = null;
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    final deviceId = selectedDevice?.deviceId;
    if (deviceId == null) return;

    for (var characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        onCalibrationCallback(await UniversalBle.readValue(
            deviceId, service.uuid, btChrCalibration));
        await UniversalBle.setNotifiable(deviceId, service.uuid,
            characteristic.uuid, BleInputProperty.notification);
        onStateChange();
        return;
      }
    }
  }
}
