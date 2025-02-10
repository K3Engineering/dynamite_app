import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();
  static const netDelay = Duration(seconds: 1);
  static const hwDelay = Duration(milliseconds: 200);
  static const dataInterval = Duration(milliseconds: 50);

  MockBlePlatform._() {
    _setupListeners();
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    await Future.delayed(hwDelay);
    return AvailabilityState.poweredOn;
  }

  @override
  Future<bool> enableBluetooth() async {
    Future.delayed(hwDelay);
    return true;
  }

  @override
  Future<bool> disableBluetooth() async {
    Future.delayed(hwDelay);
    if (_connectionState != BleConnectionState.disconnected) {
      disconnect(_connectedDeviceId!);
    }
    return true;
  }

  static List<BleDevice> _generateDevices() {
    return [
      BleDevice(
        deviceId: '1',
        name: '1_device',
        services: ['1_ser'],
        manufacturerDataList: [
          ManufacturerData(0x01, Uint8List.fromList([1, 2, 3])),
        ],
      ),
      BleDevice(
        deviceId: '2',
        name: '2_device',
        rssi: 50,
        services: ['2_ser'],
        manufacturerDataList: [
          ManufacturerData(0x02, Uint8List.fromList([2, 3, 4]))
        ],
      ),
      BleDevice(
        deviceId: '3',
        name: '3_device',
        services: ['3_ser'],
        manufacturerDataList: [
          ManufacturerData(0x03, Uint8List.fromList([3, 4, 5]))
        ],
      )
    ];
  }

  @override
  Future<void> startScan(
      {ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    if (_scanTimer != null) return;

    final rng = Random(555);
    final List<BleDevice> devices = _generateDevices();
    _scanTimer = Timer.periodic(netDelay, (Timer t) {
      if (0 == rng.nextInt(2)) {
        updateScanResult(devices[rng.nextInt(devices.length)]);
      }
      if (0 == rng.nextInt(3)) {
        updateScanResult(devices[rng.nextInt(devices.length)]);
      }
      if (0 == rng.nextInt(4)) {
        updateScanResult(devices[rng.nextInt(devices.length)]);
      }
    });
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    return (_connectedDeviceId == deviceId)
        ? _connectionState
        : BleConnectionState.disconnected;
  }

  @override
  Future<void> connect(String deviceId, {Duration? connectionTimeout}) async {
    if (_connectedDeviceId != null) return;

    _connectedDeviceId = deviceId;
    _connectionState = BleConnectionState.connecting;
    await Future.delayed(netDelay);
    _connectionState = BleConnectionState.connected;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectionState = BleConnectionState.disconnected;
    _connectedDeviceId = null;
    updateConnection(deviceId, false);
  }

  static List<BleCharacteristic> _generateCharacteristics(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleCharacteristic("beb5483e-36e1-4688-b7f5-ea07361b26a8",
            [CharacteristicProperty.notify]),
        BleCharacteristic('c1234567', [CharacteristicProperty.notify]),
        BleCharacteristic('a7654321', [CharacteristicProperty.read])
      ]);
    }
    return ([
      BleCharacteristic('c1234567', [CharacteristicProperty.notify]),
      BleCharacteristic('a7654321', [CharacteristicProperty.read])
    ]);
  }

  static List<BleService> _generateServices(String deviceId) {
    return ([
      BleService('e1234567', _generateCharacteristics(deviceId)),
      BleService('e7654321', _generateCharacteristics(deviceId))
    ]);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    await Future.delayed(netDelay);
    return _generateServices(deviceId);
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    _notificationTimer?.cancel();
    _notificationTimer = null;
    if (BleInputProperty.notification == bleInputProperty) {
      final ev =
          Uint8List.fromList([0, 0, 0, 5, 0, 0, 6, 0, 0, 7, 0, 0, 8, 0, 0]);
      _notificationTimer = Timer.periodic(dataInterval, (Timer t) {
        updateCharacteristicValue(deviceId, characteristic, ev);
      });
    }
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    final Duration? timeout,
  }) async {
    await Future.delayed(netDelay);
    return Uint8List(0);
  }

  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    return 244;
  }

  @override
  Future<bool> isPaired(String deviceId) async {
    return true;
  }

  @override
  Future<bool> pair(String deviceId) async {
    updatePairingState(deviceId, true);
    return true;
  }

  @override
  Future<void> unpair(String deviceId) async {
    updatePairingState(deviceId, false);
  }

  @override
  Future<List<BleDevice>> getSystemDevices(
    List<String>? withServices,
  ) async {
    return ([]);
  }

  void _setupListeners() {
    //onValueChange = (String deviceId, String characteristicId, Uint8List value) {};
  }
}
