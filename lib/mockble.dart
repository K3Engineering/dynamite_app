import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:universal_ble/universal_ble.dart';

import 'bt_device_config.dart';

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();
  static const netDelay = Duration(seconds: 1);
  static const hwDelay = Duration(milliseconds: 200);

  MockBlePlatform._() {
    _setupListeners();
    _mockData.clear();
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  final List<Uint8List> _mockData = [];
  int _mockDataCount = 0;

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

  @override
  Future<void> startScan(
      {ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    if (_scanTimer != null) return;

    final rng = Random(555);
    final List<BleDevice> devices = _generateDevices();
    List<BleDevice> filtered = [];
    if (scanFilter == null || scanFilter.withServices.isEmpty) {
      filtered = devices;
    } else {
      for (final dev in devices) {
        if (dev.services.any((e) {
          return scanFilter.withServices.contains(e);
        })) {
          filtered.add(dev);
        }
      }
    }
    _scanTimer = Timer.periodic(netDelay, (Timer t) {
      if (0 == rng.nextInt(2)) {
        updateScanResult(filtered[rng.nextInt(filtered.length)]);
      }
      if (0 == rng.nextInt(3)) {
        updateScanResult(filtered[rng.nextInt(filtered.length)]);
      }
      if (0 == rng.nextInt(4)) {
        updateScanResult(filtered[rng.nextInt(filtered.length)]);
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
    if (_mockData.isEmpty) {
      await _setupMockData();
    }
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
        final ev = Uint8List(adcSampleLength * samplesPerPack);
        for (int i = 0; i < samplesPerPack; ++i) {
          for (int j = 0; j < adcSampleLength; ++j) {
            ev[i * adcSampleLength + j] = _mockData[_mockDataCount][j];
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

  Future<void> _setupMockData() async {
    try {
      final String mem =
          await XFile('MockData.txt').readAsString(encoding: ascii);
      final List<String> textData = mem.split('\n');
      for (final String s in textData) {
        if (s.isEmpty) continue;

        final Map<String, dynamic> parsedLine =
            json.decode(s.replaceAll("'", '"'));
        final adcSamples = List<int>.from(parsedLine['channels']);
        assert(adcSamples.length == 4);
        final networkFormatData = Uint8List(adcSampleLength);
        for (int i = adcSamples.length - 1; i >= 0; --i) {
          networkFormatData.buffer
              .asByteData()
              .setInt32(1 + i * 3, adcSamples[i], Endian.big);
        }
        _mockData.add(networkFormatData);
      }
    } catch (err) {
      // Could not read the file
    }

    if (_mockData.isEmpty) {
      _mockData.add(
          Uint8List.fromList([0, 0, 5, 4, 3, 6, 5, 4, 7, 6, 5, 8, 7, 6, 0]));
    }
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
        services: [btServiceId],
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

  static List<BleCharacteristic> _generateCharacteristics(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleCharacteristic(btChrAdcFeedId, [CharacteristicProperty.notify]),
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
        BleService(btServiceId, _generateCharacteristics(deviceId))
      ]);
    }
    return ([
      BleService('e1234567', _generateCharacteristics(deviceId)),
      BleService('e7654321', _generateCharacteristics(deviceId))
    ]);
  }
}
