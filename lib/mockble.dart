import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:universal_ble/universal_ble.dart';

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();
  static const netDelay = Duration(seconds: 1);
  static const hwDelay = Duration(milliseconds: 200);

  MockBlePlatform._() {
    _setupListeners();
    _mockData.clear();

    const String fileName = 'MockData.txt';
    if (File(fileName).existsSync()) {
      final List<String> textData =
          File(fileName).readAsLinesSync(encoding: ascii);
      for (final String s in textData) {
        final Map<String, dynamic> parsedLine =
            json.decode(s.replaceAll("'", '"'));
        final List<int> adcSamples = List<int>.from(parsedLine['channels']);
        assert(adcSamples.length == 4);
        final Uint8List networkFormatData = Uint8List(_mockDataSampleLength);
        for (int i = 0; i < adcSamples.length; ++i) {
          networkFormatData.buffer
              .asByteData()
              .setInt32(2 + i * 3, adcSamples[i], Endian.little);
        }
        _mockData.add(networkFormatData);
      }
    }

    if (_mockData.isEmpty) {
      _mockData.add(
          Uint8List.fromList([0, 0, 5, 4, 3, 6, 5, 4, 7, 6, 5, 8, 7, 6, 0]));
    }
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  late final List<Uint8List> _mockData = [];
  int _mockDataCount = 0;
  static const int _mockDataSampleLength = 15;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    await Future<void>.delayed(hwDelay);
    return AvailabilityState.poweredOn;
  }

  @override
  Future<bool> enableBluetooth() async {
    await Future<void>.delayed(hwDelay);
    return true;
  }

  @override
  Future<bool> disableBluetooth() async {
    await Future<void>.delayed(hwDelay);
    if (_connectionState != BleConnectionState.disconnected) {
      await disconnect(_connectedDeviceId!);
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
        rssi: -50,
        services: ['e331016b-6618-4f8f-8997-1a2c7c9e5fa3'],
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
    await Future<void>.delayed(netDelay);
    _connectionState = BleConnectionState.connected;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectionState = BleConnectionState.disconnected;
    await setNotifiable(deviceId, '', '', BleInputProperty.disabled);
    _connectedDeviceId = null;
    updateConnection(deviceId, false);
  }

  static List<BleCharacteristic> _generateCharacteristics(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleCharacteristic('beb5483e-36e1-4688-b7f5-ea07361b26a8',
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
    if (deviceId == '2') {
      return ([
        BleService('e1234567', _generateCharacteristics(deviceId)),
        BleService('e331016b-6618-4f8f-8997-1a2c7c9e5fa3',
            _generateCharacteristics(deviceId))
      ]);
    }
    return ([
      BleService('e1234567', _generateCharacteristics(deviceId)),
      BleService('e7654321', _generateCharacteristics(deviceId))
    ]);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    await Future<void>.delayed(netDelay);
    return _generateServices(deviceId);
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    _notificationTimer?.cancel();
    _notificationTimer = null;
    if (BleInputProperty.notification == bleInputProperty) {
      const int samplesPerPack = 16;
      const dataInterval = Duration(milliseconds: 1 * samplesPerPack);
      _notificationTimer = Timer.periodic(dataInterval, (_) {
        final Uint8List ev = Uint8List(_mockDataSampleLength * samplesPerPack);
        for (int i = 0; i < samplesPerPack; ++i) {
          for (int j = 0; j < _mockDataSampleLength; ++j) {
            ev[i * _mockDataSampleLength + j] = _mockData[_mockDataCount][j];
          }
          _mockDataCount++;
          if (_mockDataCount >= _mockData.length) {
            _mockDataCount = 0;
          }
        }
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
    await Future<void>.delayed(netDelay);
    return Uint8List(255);
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
