import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';

class BleMockChannel {}

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();

  MockBlePlatform._() {
    _setupListeners();
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    return AvailabilityState.poweredOn;
  }

  @override
  Future<bool> enableBluetooth() async {
    return true;
  }

  @override
  Future<void> startScan({ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    var rng = Random();
    _scanTimer = Timer.periodic(Duration(seconds: 1), (Timer t) {
      final List<BleDevice> devices = [
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
      if (0 == rng.nextInt(2)) updateScanResult(devices[rng.nextInt(devices.length)]);
      if (0 == rng.nextInt(3)) updateScanResult(devices[rng.nextInt(devices.length)]);
      if (0 == rng.nextInt(4)) updateScanResult(devices[rng.nextInt(devices.length)]);
    });
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    return _connectedDeviceId == deviceId ? BleConnectionState.connected : BleConnectionState.disconnected;
  }

  @override
  Future<void> connect(String deviceId, {Duration? connectionTimeout}) async {
    _connectedDeviceId = deviceId;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectedDeviceId = null;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    final completer = Completer<void>();
    Timer(Duration(seconds: 3), completer.complete);
    await completer.future;
    BleCharacteristic chr = (deviceId == '2')
        ? BleCharacteristic("beb5483e-36e1-4688-b7f5-ea07361b26a8", [CharacteristicProperty.notify])
        : BleCharacteristic('c1234567', [CharacteristicProperty.notify]);
    BleService d0 = BleService('e1234567', [chr]);
    return ([d0]);
  }

  @override
  Future<void> setNotifiable(
      String deviceId, String service, String characteristic, BleInputProperty bleInputProperty) async {
    _notificationTimer?.cancel();
    _notificationTimer = null;
    if (BleInputProperty.notification == bleInputProperty) {
      final ev = Uint8List.fromList([1, 0, 0, 5, 0, 0, 6, 0, 0]);
      _notificationTimer = Timer.periodic(Duration(seconds: 1), (Timer t) {
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
    return Uint8List(0);
  }

  @override
  Future<void> writeValue(String deviceId, String service, String characteristic, Uint8List value,
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
    return true;
  }

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<List<BleDevice>> getSystemDevices(
    List<String>? withServices,
  ) async {
    return ([]);
  }

  void _setupListeners() {
    onValueChange = (String deviceId, String characteristicId, Uint8List value) {};
  }
}
