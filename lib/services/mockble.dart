import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'adc_protocol.dart';
import 'bt_device_config.dart';
import 'demo_calibration.dart';

class MockBlePlatform extends UniversalBlePlatform {
  static MockBlePlatform? _instance;
  static MockBlePlatform get instance => _instance ??= MockBlePlatform._();
  static const netDelay = Duration(seconds: 1);
  static const hwDelay = Duration(milliseconds: 200);

  MockBlePlatform._() {
    // Always have a synthetic feed available synchronously so [connect] never
    // blocks on file I/O (which would stall under a fake-async test clock).
    _mockData
      ..clear()
      ..addAll(_generateSyntheticFrames(2000));
  }

  Timer? _scanTimer;
  Timer? _notificationTimer;
  String? _connectedDeviceId;
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  final List<Uint8List> _mockData = [];
  int _mockDataCount = 0;
  int _packetCount = 0;

  /// Number of generated packets (emitted or dropped) since the feed started.
  int _generatedPacketCount = 0;

  /// When > 0, every [dropEveryNPackets]-th packet is *not* delivered to the
  /// client (its sample counter is still consumed), so the running sample
  /// counter jumps and [AdcPacketDecoder] reports the dropped range to
  /// [DataHub.gaps]. 0 disables induced drops (the default). The very first
  /// packet is always delivered so the decoder can establish continuity.
  int dropEveryNPackets = 0;

  /// Test knobs ---------------------------------------------------------------

  /// When false, [discoverServices] reports a GATT table WITHOUT the ADC feed
  /// service, so post-connect setup cannot subscribe to the feed.
  bool includeAdcService = true;

  /// When true, reads of the calibration characteristic throw.
  bool failCalibrationRead = false;

  /// When true, [connect] throws (a refused/failed attempt: no link is
  /// established and no connection-change callback fires — the WEB flavor,
  /// where gatt.connect() itself rejects).
  bool failConnect = false;

  /// When true, [connect] fails the way NATIVE stacks report a refused GATT
  /// connect: the platform call itself succeeds, then the refusal arrives via
  /// the connection-change callback (deviceId, false, error) — which is also
  /// what errors the client's connect() future (universal_ble completes its
  /// completer from that same event stream, AFTER the client's
  /// onConnectionChange handler has run).
  bool failConnectViaCallback = false;

  /// When true, [startScan] throws instead of starting the result feed (a
  /// refused scan start, e.g. a radio error).
  bool failScan = false;

  /// When true, [disconnect] never fires the connection-change callback, so
  /// the client's disconnect-timeout reconciliation path is what tears the
  /// link down.
  bool hangDisconnect = false;

  /// When true, [connect] takes [slowConnectDelay] instead of [netDelay] —
  /// far longer than the client's connect timeout, so the attempt is torn
  /// down before the platform link comes up. The late success still fires
  /// its connection-change callback afterwards (the "connect completed after
  /// the client gave up" race).
  bool slowConnect = false;
  static const slowConnectDelay = Duration(seconds: 20);

  /// Test spy: every deviceId passed to [disconnect], in order. Lets tests
  /// assert that leaked/unwanted GATT links were released.
  final List<String> disconnectCalls = [];

  /// Test spy: how many [readRssi] calls arrived (e.g. to assert no RSSI
  /// polling runs against the demo device).
  int readRssiCalls = 0;

  /// The device the mock currently considers linked (test assertions only).
  String? get connectedDeviceId => _connectedDeviceId;

  /// Reset every knob to its default and silently sever any leftover link
  /// (no callbacks), so the singleton is clean for the next test.
  void resetKnobs() {
    dropEveryNPackets = 0;
    includeAdcService = true;
    failCalibrationRead = false;
    failConnect = false;
    failConnectViaCallback = false;
    failScan = false;
    hangDisconnect = false;
    slowConnect = false;
    disconnectCalls.clear();
    readRssiCalls = 0;
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
    // Real platforms stamp every scan result with its receipt time, and the
    // manager's "last seen" freshness (BleLinkManager.lastAliveMs) relies on
    // it — re-stamp on each emission so mock devices age/refresh like real
    // advertisements instead of carrying a stale (or null) timestamp.
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
  }) async {
    if (_connectedDeviceId != null) return;

    _connectedDeviceId = deviceId;
    _connectionState = BleConnectionState.connecting;
    await Future<void>.delayed(slowConnect ? slowConnectDelay : netDelay);
    if (failConnect) {
      // A refused/failed attempt: no link, and no connection-change callback
      // — the client's connect() catch path is what tears its state down.
      _connectedDeviceId = null;
      _connectionState = BleConnectionState.disconnected;
      throw StateError('Mock connect failure');
    }
    if (failConnectViaCallback) {
      // The native refusal flavor: the platform call itself succeeds; the
      // refusal arrives via the connection-change callback — which is ALSO
      // what errors the client's connect() future (universal_ble completes
      // its completer from this same event stream, after the client's
      // onConnectionChange handler has run synchronously).
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
      // Never fire the connection-change callback: the link stays "connected"
      // here and the client's disconnect-timeout reconciliation tears it down.
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
      // A device whose GATT table lacks the ADC feed service.
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
    // The feed is reset on every (re)subscription: continuity counter and the
    // synthetic-data cursor both restart from zero so reconnects behave like a
    // fresh device, and an induced-drop run can be repeated deterministically.
    _notificationTimer?.cancel();
    _notificationTimer = null;
    _packetCount = 0;
    _mockDataCount = 0;
    _generatedPacketCount = 0;

    if (BleInputProperty.notification == bleInputProperty) {
      // One packet every [nwAdcNumSamples] ms => 1000 samples/sec (matches
      // DataHub.samplesPerSec), with [nwAdcNumSamples] samples per packet.
      const dataInterval = Duration(milliseconds: nwAdcNumSamples);
      _notificationTimer = Timer.periodic(dataInterval, (_) {
        final int thisCounter = _packetCount;
        // Always advance the running counter by a full packet, whether or not
        // we deliver this packet, so a dropped packet produces a real gap.
        _packetCount = (_packetCount + nwAdcNumSamples) & 0xFFFF;

        final bool drop =
            dropEveryNPackets > 0 &&
            _generatedPacketCount > 0 &&
            (_generatedPacketCount % dropEveryNPackets) == 0;
        _generatedPacketCount++;
        if (drop) return;

        final ev = encodeAdcPacket(
          counter: thisCounter,
          frames: [
            for (int i = 0; i < nwAdcNumSamples; ++i)
              _mockData[(_mockDataCount + i) % _mockData.length],
          ],
        );
        _mockDataCount = (_mockDataCount + nwAdcNumSamples) % _mockData.length;
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
    await Future<void>.delayed(netDelay);
    if (characteristic == btChrCalibration) {
      if (failCalibrationRead) {
        throw StateError('Mock calibration read failure');
      }
      // The mock device is factory-calibrated: serve the shared fixture doc.
      return Uint8List.fromList(utf8.encode(demoBoardCalibrationDoc));
    }
    return Uint8List(255);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    return 244;
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

  /// Generate [count] deterministic multi-channel frames so the mock feed
  /// looks like real data when no MockData.txt is present. Channel 0/1 are
  /// sines with a phase offset, channel 2 a cosine, channel 3 a slow sawtooth;
  /// amplitudes stay well inside the signed 24-bit range.
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
        BleCharacteristic('c1234567', [CharacteristicProperty.notify], []),
        BleCharacteristic('a7654321', [CharacteristicProperty.read], []),
      ]);
    }
    return ([
      BleCharacteristic('c1234567', [CharacteristicProperty.notify], []),
      BleCharacteristic('a7654321', [CharacteristicProperty.read], []),
    ]);
  }

  static List<BleService> _generateServices(String deviceId) {
    if (deviceId == '2') {
      return ([
        BleService('e1234567', _generateCharacteristics(deviceId)),
        BleService(btServiceId, _generateCharacteristics(deviceId)),
      ]);
    }
    return ([
      BleService('e1234567', _generateCharacteristics(deviceId)),
      BleService('e7654321', _generateCharacteristics(deviceId)),
    ]);
  }
}
