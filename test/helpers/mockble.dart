import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'package:dynamite_app/services/ota_protocol.dart';
import 'package:dynamite_app/models/device_flash.dart';

/// Samples per emitted feed packet (20 ms at 1 kHz, matching the mock's ADC
/// config readback).
const int _samplesPerPacket = 20;

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();

  static const netDelay = Duration(seconds: 1);
  static const hwDelay = Duration(milliseconds: 200);

  MockBlePlatform._() {
    // Synthetic feed built synchronously so [connect] never blocks on file I/O.
    _mockData
      ..clear()
      ..addAll(_generateSyntheticFrames(2000));
    seedKvs(demoKvs);
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  /// Whether the client holds the ADC feed subscription (see
  /// [kvsLockWhenStreaming]).
  bool _adcFeedSubscribed = false;

  final List<Uint8List> _mockData = [];
  int _mockDataCount = 0;
  int _packetCount = 0;

  /// Number of generated packets (emitted or dropped) since the feed started.
  int _generatedPacketCount = 0;

  /// When > 0, every Nth packet is not delivered (its counter still advances),
  /// so [AdcPacketDecoder] reports a gap. The first packet is always delivered.
  int dropEveryNPackets = 0;

  /// Test knobs ---------------------------------------------------------------

  /// When false, the GATT table omits the ADC feed service.
  bool includeAdcService = true;

  /// When true, the ADC config read serves garbage, failing the connection.
  bool badAdcConfig = false;

  /// When true, KVS commands throw, failing the connect-time flash read.
  bool failKvsCommands = false;

  /// When true, KVS commands answer 'B' (busy) while the feed is subscribed.
  bool kvsLockWhenStreaming = false;

  /// When true, KVS commands get no answer (exercises the client timeout).
  bool kvsDropCommands = false;

  /// When true, enabling the ADC feed subscription throws. Set after streaming
  /// to fail only a feed-pause resubscribe.
  bool failFeedSubscribe = false;

  /// How long a KVS command takes to answer (default instant).
  Duration kvsCommandDelay = Duration.zero;

  /// The mock device's KVS, per folder. Seeded from [demoKvs]; writes
  /// mutate it, so reads serve whatever was last written (like real flash).
  final Map<String, Map<String, String>> kvsStore = {
    kvsFolderFactory: {},
    kvsFolderUser: {},
    kvsFolderSettings: {},
  };

  /// Test knob: the OTA request is answered with a NAK.
  bool refuseOtaStart = false;

  /// Test spy: image bytes received on the OTA Data characteristic.
  int otaDataBytes = 0;

  /// Test spy: every KVS command received, in order.
  final List<String> kvsCommandLog = [];

  /// Test spy: GATT ops in device-observed order (`adc:sub`/`adc:unsub`,
  /// `kvs:<request>`).
  final List<String> gattOpLog = [];

  /// (Re)populate [kvsStore] from [snapshot], its folders written verbatim.
  void seedKvs(KvsSnapshot snapshot) {
    for (final folder in kvsStore.values) {
      folder.clear();
    }
    kvsStore[kvsFolderFactory]!.addAll(snapshot.factory);
    kvsStore[kvsFolderUser]!.addAll(snapshot.user);
  }

  /// When true, [connect] throws and no connection-change callback fires (the
  /// web flavor).
  bool failConnect = false;

  /// When true, [connect] succeeds then fails via the connection-change callback
  /// (the native refusal flavor).
  bool failConnectViaCallback = false;

  /// When true, [startScan] throws.
  bool failScan = false;

  /// When false, the adapter reports poweredOff; [enableBluetooth] flips it.
  bool isEnabled = true;

  /// When true, [enableBluetooth] returns false and leaves the radio off.
  bool refuseEnable = false;

  /// Test spy: how many [requestPermissions] calls arrived.
  int requestPermissionsCalls = 0;

  /// When true, [disconnect] never fires the callback (exercises the client's
  /// disconnect timeout).
  bool hangDisconnect = false;

  /// When true, [connect] takes [slowConnectDelay] (past the client's connect
  /// timeout); the late success still fires its callback afterwards.
  bool slowConnect = false;
  static const slowConnectDelay = Duration(seconds: 20);

  /// Test spy: every deviceId passed to [disconnect], in order.
  final List<String> disconnectCalls = [];

  /// Test spy: how many [readRssi] calls arrived.
  int readRssiCalls = 0;

  /// The device the mock currently considers linked (test assertions only).
  String? get connectedDeviceId => _connectedDeviceId;

  /// Reset every knob to default and silently sever any leftover link.
  void resetKnobs() {
    dropEveryNPackets = 0;
    includeAdcService = true;
    badAdcConfig = false;
    failKvsCommands = false;
    kvsLockWhenStreaming = false;
    kvsDropCommands = false;
    failFeedSubscribe = false;
    kvsCommandDelay = Duration.zero;
    failConnect = false;
    failConnectViaCallback = false;
    failScan = false;
    isEnabled = true;
    refuseEnable = false;
    requestPermissionsCalls = 0;
    hangDisconnect = false;
    slowConnect = false;
    disconnectCalls.clear();
    readRssiCalls = 0;
    refuseOtaStart = false;
    otaDataBytes = 0;
    kvsCommandLog.clear();
    gattOpLog.clear();
    seedKvs(demoKvs);
    _adcFeedSubscribed = false;
    _connectedDeviceId = null;
    _connectionState = BleConnectionState.disconnected;
    _scanTimer?.cancel();
    _scanTimer = null;
    _notificationTimer?.cancel();
    _notificationTimer = null;
  }

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    await Future<void>.delayed(hwDelay);
    return isEnabled
        ? AvailabilityState.poweredOn
        : AvailabilityState.poweredOff;
  }

  @override
  Future<bool> enableBluetooth() async {
    await Future<void>.delayed(hwDelay);
    if (refuseEnable) return false;
    isEnabled = true;
    return true;
  }

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {
    requestPermissionsCalls++;
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
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    if (failScan) {
      throw StateError('Mock scan failure');
    }
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
    // Re-stamp each emission with its receipt time, like real adverts, so the
    // manager's "last seen" freshness works.
    void emit(BleDevice d) {
      d.timestamp = DateTime.now().millisecondsSinceEpoch;
      updateScanResult(d);
    }

    _scanTimer = Timer.periodic(netDelay, (Timer t) {
      if (0 == rng.nextInt(2)) {
        emit(filtered[rng.nextInt(filtered.length)]);
      }
      if (0 == rng.nextInt(3)) {
        emit(filtered[rng.nextInt(filtered.length)]);
      }
      if (0 == rng.nextInt(4)) {
        emit(filtered[rng.nextInt(filtered.length)]);
      }
    });
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  @override
  Future<bool> isScanning() async {
    return _scanTimer != null;
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    return (_connectedDeviceId == deviceId)
        ? _connectionState
        : BleConnectionState.disconnected;
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    if (_connectedDeviceId != null) return;

    _connectedDeviceId = deviceId;
    _connectionState = BleConnectionState.connecting;
    await Future<void>.delayed(slowConnect ? slowConnectDelay : netDelay);
    if (failConnect) {
      // No link and no callback; the client's connect() catch path tears down.
      _connectedDeviceId = null;
      _connectionState = BleConnectionState.disconnected;
      throw StateError('Mock connect failure');
    }
    if (failConnectViaCallback) {
      // The native refusal flavor: the callback both reports the failure and
      // errors the client's connect() future.
      _connectedDeviceId = null;
      _connectionState = BleConnectionState.disconnected;
      updateConnection(deviceId, false, 'Mock connect refusal');
      return;
    }
    _connectionState = BleConnectionState.connected;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
    if (hangDisconnect) {
      // No callback: the client's disconnect-timeout reconciliation tears it
      // down.
      return;
    }
    _connectionState = BleConnectionState.disconnected;
    await setNotifiable(deviceId, '', '', BleInputProperty.disabled);
    _connectedDeviceId = null;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId, bool _) async {
    await Future<void>.delayed(netDelay);
    final services = _generateServices(deviceId);
    if (!includeAdcService) {
      return [
        for (final s in services)
          if (s.uuid != btServiceId) s,
      ];
    }
    return services;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    if (failFeedSubscribe &&
        characteristic == btChrAdcFeedId &&
        bleInputProperty == BleInputProperty.notification) {
      throw StateError('Mock feed subscribe failure');
    }
    // Only the ADC feed drives the packet timer; KVS is request/response.
    if (characteristic.isNotEmpty && characteristic != btChrAdcFeedId) {
      return;
    }
    _adcFeedSubscribed = bleInputProperty == BleInputProperty.notification;
    if (characteristic == btChrAdcFeedId) {
      gattOpLog.add(_adcFeedSubscribed ? 'adc:sub' : 'adc:unsub');
    }
    // Reset the feed on every (re)subscription so reconnects and drop runs are
    // deterministic.
    _notificationTimer?.cancel();
    _notificationTimer = null;
    _packetCount = 0;
    _mockDataCount = 0;
    _generatedPacketCount = 0;

    if (BleInputProperty.notification == bleInputProperty) {
      const dataInterval = Duration(milliseconds: _samplesPerPacket);
      _notificationTimer = Timer.periodic(dataInterval, (_) {
        final int thisCounter = _packetCount;
        // Advance the counter even when dropping, so a drop produces a real gap.
        _packetCount = (_packetCount + _samplesPerPacket) & 0xFFFF;

        final bool drop =
            dropEveryNPackets > 0 &&
            _generatedPacketCount > 0 &&
            (_generatedPacketCount % dropEveryNPackets) == 0;
        _generatedPacketCount++;
        if (drop) return;

        final ev = encodeAdcPacket(
          counter: thisCounter,
          frames: [
            for (int i = 0; i < _samplesPerPacket; ++i)
              _mockData[(_mockDataCount + i) % _mockData.length],
          ],
        );
        _mockDataCount =
            (_mockDataCount + _samplesPerPacket) % _mockData.length;
        updateCharacteristicValue(deviceId, characteristic, ev, null);
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
    // Static strings, served synchronously, like KVS answers.
    final String? disValue = _disValues[characteristic];
    if (service == btSvcDeviceInfo && disValue != null) {
      return Uint8List.fromList(utf8.encode(disValue));
    }
    if (characteristic == btChrAdcConfig) {
      if (badAdcConfig) return Uint8List(3);
      // ADC config: version 1; CLOCK 0x0F14 (four channels, OSR 4096 → 1000 SPS,
      // matching the feed timer); GAIN 0x0000 (PGA 1x, Pro-like).
      return Uint8List(11)
        ..[0] = 1
        ..[8] = 0x0F
        ..[7] = 0x14;
    }
    await Future<void>.delayed(netDelay);
    return Uint8List(255);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    if (characteristic == btChrKvs) {
      if (failKvsCommands) {
        throw StateError('Mock KVS command failure');
      }
      if (kvsCommandDelay > Duration.zero) {
        await Future<void>.delayed(kvsCommandDelay);
      }
      // A dead link: the command goes unanswered.
      if (kvsDropCommands) return;
      final request = utf8.decode(value, allowMalformed: true);
      kvsCommandLog.add(request);
      gattOpLog.add('kvs:$request');
      // Firmware device lock: while the feed is subscribed, KVS answers busy.
      final response = (kvsLockWhenStreaming && _adcFeedSubscribed)
          ? 'B$request'
          : _executeKvsCommand(request);
      // The response arrives within the write handler.
      updateCharacteristicValue(
        deviceId,
        btChrKvs,
        Uint8List.fromList(utf8.encode(response)),
        null,
      );
    } else if (characteristic == btChrOtaControl) {
      // The OTA control protocol in miniature: REQUEST is a 5-byte write, DONE
      // one byte; the reply fires inside the write handler.
      final reply = switch ((value[0], value.length)) {
        (otaRequestOpcode, 5) => refuseOtaStart ? otaRequestNak : otaRequestAck,
        (otaDoneOpcode, 1) => otaDoneAck,
        _ => otaRequestNak,
      };
      updateCharacteristicValue(
        deviceId,
        btChrOtaControl,
        Uint8List.fromList([reply]),
        null,
      );
    } else if (characteristic == btChrOtaData) {
      // Chunks are consumed in the write handler; no reply.
      otaDataBytes += value.length;
    }
  }

  @override
  Future<Uint8List> readDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor, {
    final Duration? timeout,
  }) => throw UnimplementedError('the mock device exposes no descriptors');

  @override
  Future<void> writeDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor,
    Uint8List value, {
    final Duration? timeout,
  }) => throw UnimplementedError('the mock device exposes no descriptors');

  /// The firmware KVS command processor in miniature.
  String _executeKvsCommand(String request) {
    String reply(bool ok, [String payload = '']) =>
        ok ? '1$request=$payload' : '0$request';

    if (request.length < 4) return reply(false);
    final cmd = request.substring(0, 3);
    final folder = request.substring(3, 4);
    final data = request.substring(4);
    final store = kvsStore[folder];
    if (store == null) return reply(false);
    switch (cmd) {
      case kvsCmdGet:
        if (data.length > kvsMaxKeyLength) return reply(false);
        final value = store[data];
        return value == null ? reply(false) : reply(true, value);
      case kvsCmdSet:
        final eq = data.indexOf('=');
        if (eq <= 0 || eq > kvsMaxKeyLength) return reply(false);
        final value = data.substring(eq + 1);
        if (value.isEmpty || value.length > kvsMaxValueLength) {
          return reply(false);
        }
        store[data.substring(0, eq)] = value;
        return reply(true);
      case kvsCmdDelete:
        if (data.length > kvsMaxKeyLength) return reply(false);
        return store.remove(data) == null ? reply(false) : reply(true);
      case kvsCmdIndex:
        final n = int.tryParse(data, radix: 16);
        if (n == null || n < 0 || n >= store.length) return reply(false);
        return reply(true, '${store.keys.elementAt(n)}=$kvsNvsTypeStrHex');
      default:
        return reply(false);
    }
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    return expectedMtu;
  }

  @override
  Future<int> readRssi(String deviceId) async {
    readRssiCalls++;
    return 1;
  }

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

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
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async {
    return ([]);
  }

  /// Generate [count] deterministic frames, well inside the 24-bit range.
  static List<Uint8List> _generateSyntheticFrames(int count) {
    const amp0 = 4000000;
    const amp1 = 3000000;
    const amp2 = 2500000;
    const amp3 = 20000;
    const cycles = 5.0;
    final frames = <Uint8List>[];
    for (int s = 0; s < count; ++s) {
      final t = s / count;
      final c0 = (sin(2 * pi * cycles * t) * amp0).round();
      final c1 = (sin(2 * pi * cycles * t + pi / 4) * amp1).round();
      final c2 = (cos(2 * pi * cycles * t) * amp2).round();
      final c3 = ((s % 200) - 100) * amp3;
      frames.add(encodeAdcFrame([c0, c1, c2, c3]));
    }
    return frames;
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
          ManufacturerData(0x02, Uint8List.fromList([2, 3, 4])),
        ],
      ),
      BleDevice(
        deviceId: '3',
        name: '3_device',
        services: ['3_ser'],
        manufacturerDataList: [
          ManufacturerData(0x03, Uint8List.fromList([3, 4, 5])),
        ],
      ),
    ];
  }

  static List<BleCharacteristic> _generateCharacteristics(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleCharacteristic(btChrAdcFeedId, [CharacteristicProperty.notify], []),
        BleCharacteristic(btChrAdcConfig, [CharacteristicProperty.read], []),
        BleCharacteristic('c1234567', [CharacteristicProperty.notify], []),
        BleCharacteristic('a7654321', [CharacteristicProperty.read], []),
      ]);
    }
    return ([
      BleCharacteristic('c1234567', [CharacteristicProperty.notify], []),
      BleCharacteristic('a7654321', [CharacteristicProperty.read], []),
    ]);
  }

  /// The mock sampler's Device Information service (0x180A) contents.
  static const Map<String, String> _disValues = {
    btChrDisManufacturer: 'K3 Engineering',
    btChrDisModel: 'Dynamite Sampler Pro Mk1',
    btChrDisSerial: 'A4CF1208F51E',
    btChrDisHardwareRev: 'v700P',
    btChrDisFirmwareRev: 'v700P|mock-1.0.0',
  };

  static List<BleService> _generateServices(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleService('e1234567', _generateCharacteristics(deviceId)),
        BleService(btServiceId, _generateCharacteristics(deviceId)),
        BleService(btSvcDeviceInfo, [
          for (final chr in _disValues.keys)
            BleCharacteristic(chr, [CharacteristicProperty.read], []),
        ]),
        BleService(otaServiceId, [
          BleCharacteristic(btChrOtaControl, [
            CharacteristicProperty.write,
            CharacteristicProperty.notify,
          ], []),
          BleCharacteristic(btChrOtaData, [CharacteristicProperty.write], []),
        ]),
      ]);
    }
    return ([
      BleService('e1234567', _generateCharacteristics(deviceId)),
      BleService('e7654321', _generateCharacteristics(deviceId)),
    ]);
  }
}
