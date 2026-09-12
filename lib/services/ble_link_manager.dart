import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'app_events.dart';
import 'adc_protocol.dart';
import 'bt_device_config.dart';
import '../models/bt_scan.dart';
import 'ota_client.dart';
import 'link_backend.dart';
import 'link_transport.dart';
import '../models/device_flash.dart';
import '../models/device_info.dart';
import '../models/device_name.dart';
import '../utils/log.dart';

enum ConnectFailureKind {
  /// On web this is typically Chrome rejecting gatt.connect() on a stale
  /// device handle (a row left over from an earlier session — universal_ble
  /// wraps the NetworkError as UniversalBleErrorCode.unknownError); the fix
  /// is a fresh Scan + pick, which mints a new handle.
  failed,

  timeout,
}

/// Packet sizes count malformed packets too.
class LinkTelemetry {
  int? rssi;
  int? minAdcPacketBytes;
  int? maxAdcPacketBytes;
}

class LinkInfo {
  LinkInfo({
    required this.transport,
    required this.advertisedName,
    required this.storedName,
    required this.info,
    required this.mtu,
    required this.adcConfig,
    required this.telemetry,
  });

  final LinkTransport transport;
  final String advertisedName;
  String? storedName;
  final DeviceInfo? info;
  final int? mtu;
  final AdcConfig adcConfig;
  final LinkTelemetry telemetry;

  String get deviceId => transport.deviceId;

  String get displayName =>
      storedName ?? (advertisedName.isEmpty ? deviceId : advertisedName);
}

sealed class Link {
  const Link();

  String get deviceId;
  LinkTransport? get transport;
  LinkTelemetry? get telemetry => null;
  String? get storedName => null;
  DeviceInfo? get deviceInfo => null;
  int? get mtu => null;
  AdcConfig? get adcConfig => null;

  /// Null until the backend is brought up.
  LinkBackend? get backend => transport?.backend;

  /// True during post-connect setup and while streaming.
  bool get isLinkUp;

  /// Feed subscribed. Not proof of data flow — see deriveFeedHealth.
  bool get isStreaming;

  BtLinkState get state;

  String get displayName {
    final t = transport;
    if (t == null) return '';
    return storedName ?? (t.displayName.isEmpty ? t.deviceId : t.displayName);
  }
}

final class NoLink extends Link {
  const NoLink();

  @override
  String get deviceId => '';

  @override
  LinkTransport? get transport => null;

  @override
  bool get isLinkUp => false;

  @override
  bool get isStreaming => false;

  @override
  BtLinkState get state => BtLinkState.idle;
}

final class Connecting extends Link {
  const Connecting(this.transport);

  @override
  final LinkTransport transport;

  @override
  String get deviceId => transport.deviceId;

  @override
  bool get isLinkUp => false;

  @override
  bool get isStreaming => false;

  @override
  BtLinkState get state => BtLinkState.connecting;
}

final class SettingUp extends Link {
  SettingUp(this.transport, this.phase);

  @override
  final LinkTransport transport;

  @override
  final LinkTelemetry telemetry = LinkTelemetry();

  /// One of [BtLinkState.connected], [BtLinkState.readingConstants],
  /// [BtLinkState.subscribing].
  BtLinkState phase;

  DeviceInfo? info;
  @override
  int? mtu;
  @override
  AdcConfig? adcConfig;
  @override
  String? storedName;

  @override
  String get deviceId => transport.deviceId;

  @override
  DeviceInfo? get deviceInfo => info;

  @override
  bool get isLinkUp => true;

  @override
  bool get isStreaming => false;

  @override
  BtLinkState get state => phase;
}

final class Ready extends Link {
  Ready(this.info);

  final LinkInfo info;

  @override
  LinkTransport get transport => info.transport;

  @override
  String get deviceId => info.deviceId;

  @override
  LinkTelemetry get telemetry => info.telemetry;

  @override
  String? get storedName => info.storedName;

  @override
  DeviceInfo? get deviceInfo => info.info;

  @override
  int? get mtu => info.mtu;

  @override
  AdcConfig get adcConfig => info.adcConfig;

  @override
  bool get isLinkUp => true;

  @override
  bool get isStreaming => true;

  @override
  BtLinkState get state => BtLinkState.streaming;
}

final class Closing extends Link {
  const Closing(this.transport);

  @override
  final LinkTransport transport;

  @override
  String get deviceId => transport.deviceId;

  @override
  bool get isLinkUp => false;

  @override
  bool get isStreaming => false;

  @override
  BtLinkState get state => BtLinkState.disconnecting;
}

/// A setup pass checks [isCurrent] after every `await` and bails when false.
/// Goes stale when [BleLinkManager._supersedeSetupPasses] runs or the active
/// link is a different device.
class _SetupToken {
  const _SetupToken(this._manager, this._epoch, this.deviceId);

  final BleLinkManager _manager;
  final int _epoch;
  final String deviceId;

  bool get isCurrent =>
      _manager._setupEpoch == _epoch && _manager._link.deviceId == deviceId;
}

/// Chrome signals picker dismissal with UserCancelledDialogError /
/// DeviceNotFoundError; Bluefy with a BrowserError carrying its own cancel
/// code. flutter_web_bluetooth rethrows these verbatim but does NOT re-export
/// the classes, so they can't be caught by type without a direct dependency
/// on the web-only package; match the toString prefix ("$errorName: …")
/// instead. A BrowserError wrapping a SecurityError (permissions-policy
/// denial) is a genuine failure. Trade-off: any other genuine BrowserError
/// is swallowed as a dismissal.
bool isWebPickerDismissal(Object e) {
  final s = e.toString();
  return s.startsWith('UserCancelledDialogError') ||
      s.startsWith('DeviceNotFoundError') ||
      (s.startsWith('BrowserError') && !s.contains('SecurityError'));
}

class BleLinkManager extends ChangeNotifier {
  /// universal_ble's disconnect() applies this timeout to its own completer
  /// over the connection-event stream, then drives [_onConnectionChange]
  /// (even in the already-disconnected case).
  static const Duration disconnectTimeout = Duration(milliseconds: 2500);

  /// connect() bypasses the package's command queue — [UniversalBle.timeout]
  /// does NOT cover it — and defaults to 60 s.
  static const Duration connectTimeout = Duration(seconds: 5);

  static const Duration rssiPollInterval = Duration(seconds: 2);

  static const Duration deviceStaleAfter = Duration(seconds: 10);

  /// After a disconnect, Web Bluetooth on Chrome needs a moment to finish
  /// tearing down GATT before it accepts a fresh connection to the SAME
  /// device. Reconnecting sooner makes Chrome briefly accept then drop the
  /// link (and throws "Cannot discover services if the device is not
  /// connected"). Web Bluetooth exposes no teardown-complete event, so the
  /// margin is a wall-clock guess. Native stacks don't exhibit the race.
  static const Duration reconnectSettleDelay = Duration(milliseconds: 4000);

  /// Per-device "do not reconnect before" embargo, stamped in [_teardownLink]
  /// for a LIVE web link only (a failed connect attempt stamps nothing). A
  /// scan kick-off leaves it standing; a successful picker pass clears it:
  /// tested on Chrome, a device mid-teardown doesn't appear in
  /// requestDevice() at all, so a pick IS the teardown-settle signal this
  /// stamp otherwise guesses at.
  final Map<String, DateTime> _reconnectNotBefore = {};

  bool reconnectPendingFor(String deviceId) {
    final notBefore = _reconnectNotBefore[deviceId];
    return notBefore != null && notBefore.isAfter(DateTime.now());
  }

  Timer? _reconnectPoke;

  int _setupEpoch = 0;

  _SetupToken _setupTokenFor(String deviceId) =>
      _SetupToken(this, _setupEpoch, deviceId);

  void _supersedeSetupPasses() => _setupEpoch++;

  BtAvailability _bluetoothState = BtAvailability.unknown;
  BtAvailability get bluetoothState => _bluetoothState;

  final List<DiscoveredDevice> _devices = [];
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  Link _link = const NoLink();

  final Map<String, ConnectFailureKind> _connectFailures = {};

  ConnectFailureKind? connectFailureFor(String deviceId) =>
      _connectFailures[deviceId];

  final Map<String, String> _lastDisconnectErrors = {};

  String? lastDisconnectErrorFor(String deviceId) =>
      _lastDisconnectErrors[deviceId];

  final Map<String, String> _setupFailures = {};

  String? setupFailureFor(String deviceId) => _setupFailures[deviceId];

  final Map<String, int> _lastAliveMs = {};

  int? lastAliveMs(String deviceId) {
    final stamp = _lastAliveMs[deviceId];
    if (kIsWeb) return stamp;
    final scanTs = _devices
        .where((d) => d.deviceId == deviceId)
        .firstOrNull
        ?.timestamp;
    if (stamp == null) return scanTs;
    if (scanTs == null) return stamp;
    return stamp > scanTs ? stamp : scanTs;
  }

  void _stampAlive(String deviceId) {
    if (deviceId.isEmpty) return;
    if (_link.transport?.isSimulated ?? false) return;
    _lastAliveMs[deviceId] = DateTime.now().millisecondsSinceEpoch;
  }

  bool get isStreaming => _link.isStreaming;

  bool get isLinkUp => _link.isLinkUp;

  bool get isSimulated => _link.transport?.isSimulated ?? false;

  BtLinkState get linkState => _link.state;

  bool get linkBusy =>
      _link.state != BtLinkState.idle ||
      _reconnectNotBefore.values.any((t) => t.isAfter(DateTime.now()));

  String get connectedDeviceId => _link.isLinkUp ? _link.deviceId : '';

  String get activeDeviceId => _link.deviceId;

  String get connectedDeviceName => _link.displayName;

  String? get connectedStoredDeviceName =>
      _link.isLinkUp ? _link.storedName : null;

  DeviceInfo? get connectedDeviceInfo =>
      _link.isLinkUp ? _link.deviceInfo : null;

  int? get negotiatedMtu => _link.isLinkUp ? _link.mtu : null;

  int? get minAdcPacketBytes =>
      _link.isLinkUp ? _link.telemetry?.minAdcPacketBytes : null;

  int? get maxAdcPacketBytes =>
      _link.isLinkUp ? _link.telemetry?.maxAdcPacketBytes : null;

  int? get connectedRssi => _link.isStreaming ? _link.telemetry?.rssi : null;

  LinkBackend? get backend => _link.backend;

  /// Web throws notImplemented for UniversalBle.readRssi.
  bool get _supportsRssi => !kIsWeb;

  /// On web scan results never carry RSSI: the "scan" is Chrome's
  /// requestDevice() picker, which has no RSSI, and the only other path
  /// (watchAdvertisements) is flag-gated and abandoned by Chrome.
  bool get supportsScanRssi => !kIsWeb;

  Timer? _rssiPollTimer;

  bool _devicesTabVisible = false;

  void setDevicesTabVisible(bool visible) {
    if (_devicesTabVisible == visible) return;
    _devicesTabVisible = visible;
    _syncFreshnessPoke();
  }

  Timer? _freshnessPoke;

  void _syncFreshnessPoke() {
    final shouldRun = _devicesTabVisible && _devices.isNotEmpty;
    if (shouldRun && _freshnessPoke == null) {
      _freshnessPoke = Timer.periodic(
        const Duration(seconds: 1),
        (_) => notifyListeners(),
      );
    } else if (!shouldRun) {
      _freshnessPoke?.cancel();
      _freshnessPoke = null;
    }
  }

  void Function(Uint8List data) _onAdcData;

  final void Function(DeviceFlash flash) onDeviceFlash;

  void Function(int sampleRateHz) _onSampleRate;

  bool get linkIsSimulated => isSimulated && isLinkUp;

  final AppEvents _events;

  /// Null only in tests.
  final LinkTransport? _demo;

  /// [KvsClient] serializes individual KVS commands, but nothing stops one
  /// envelope's resubscribe from landing inside the NEXT envelope's command
  /// body — locking the device against its remaining commands. Envelopes
  /// chain here so each runs to completion before the next starts.
  Future<void> _feedMaintenance = Future.value();

  /// Run [body] as an OTA flash session against the live link. A body that
  /// RETURNS had its image accepted — the device reboots into it ~0.5 s later
  /// (see [OtaClient.flash]) — so the link is then ended via the
  /// requested-disconnect path. A body that THROWS keeps the link (nothing
  /// rebooted): the feed resumes and the error reaches the caller.
  Future<T> runOta<T>(Future<T> Function(OtaClient client) body) async {
    final transport = _link.transport;
    if (transport == null) {
      throw StateError('OTA requires a connected device');
    }
    return transport.runOta((client) async {
      final result = await body(client);
      // The reboot may already have dropped the link on its own.
      if (identical(_link.transport, transport)) {
        await disconnectSelectedDevice();
      }
      return result;
    });
  }

  /// Firmware rejects KVS commands while the feed's subscription holds the
  /// device lock, so doc writes (and the verifying re-read) unsubscribe, run,
  /// resubscribe. The feed's counter jump on resume surfaces as a gap via the
  /// decoder's continuity check.
  Future<T> _withFeedPaused<T>(Future<T> Function() body) {
    final op = _feedMaintenance.then((_) => _feedPausedEnvelope(body));
    _feedMaintenance = op.then<void>((_) {}, onError: (_) {});
    return op;
  }

  /// The firmware releases its device lock inside the CCC-write callback,
  /// ahead of the unsubscribe's completion — but only when the platform
  /// actually ordered and awaited the descriptor write. A KVS write that
  /// lands while the lock still holds is dropped silently and costs a full
  /// command timeout.
  static const Duration _feedPauseSettle = Duration(milliseconds: 300);

  Future<T> _feedPausedEnvelope<T>(Future<T> Function() body) async {
    final link = _link;
    if (link is! Ready) return body();
    final transport = link.info.transport;
    await transport.unsubscribeFromAdcFeed();
    await Future<void>.delayed(_feedPauseSettle);
    try {
      return await body();
    } finally {
      if (_link is Ready && identical(_link.transport, transport)) {
        try {
          await transport.subscribeToAdcFeed();
        } catch (_) {
          // A dead feed with no retry path: tear down, like a failed
          // subscribe at connect time.
          final name = link.info.displayName;
          _teardownLink(transport, releasePlatform: true);
          _events.emit(BleConnectionLost(name));
          notifyListeners();
          rethrow;
        }
      }
    }
  }

  /// Input is trimmed; empty (post-trim) CLEARS the name. Returns false when
  /// the device rejects the write; throws on invalid input or no link.
  Future<bool> setDeviceName(String name) async {
    final link = _link;
    if (link is! Ready) {
      throw StateError('setDeviceName with no device connected');
    }
    final trimmed = name.trim();
    if (trimmed.isNotEmpty && !isValidDeviceName(trimmed)) {
      throw ArgumentError.value(name, 'name', 'invalid device name');
    }
    final stored = trimmed.isEmpty ? null : trimmed;
    final ok = await link.transport.backend!.storeDeviceName(stored);
    if (ok) {
      link.info.storedName = stored;
      notifyListeners();
    }
    return ok;
  }

  BleLinkManager({
    required AppEvents events,
    required this.onDeviceFlash,
    required void Function(Uint8List data) onAdcData,
    required void Function(int sampleRateHz) onSampleRate,
    LinkTransport? demo,
  }) : _events = events,
       _onAdcData = onAdcData,
       _onSampleRate = onSampleRate,
       _demo = demo {
    // With the default `global` queue, a command stuck against a half-torn-down
    // device (common on web when the user rapidly connects/disconnects) blocks
    // and serially times out every later command — a storm of 10s "Future not
    // completed" failures. `perDevice` isolates a dead device's stuck commands
    // from a fresh attempt.
    UniversalBle.queueType = QueueType.perDevice;
    // Default is 10 s; a hung web GATT promise should surface sooner.
    UniversalBle.timeout = const Duration(seconds: 5);
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onConnectionParametersChange = _onConnectionParametersChange;
    UniversalBle.onValueChange = _onValueChange;

    unawaited(_updateBluetoothState());
  }

  Future<void> _updateBluetoothState() async {
    _bluetoothState = BtAvailability.values.byName(
      (await UniversalBle.getBluetoothAvailabilityState()).name,
    );
    notifyListeners();
  }

  /// [UniversalBle.timeout] (5 s) is shorter than a human reading a dialog.
  static const Duration _enableDialogTimeout = Duration(minutes: 2);

  /// Permissions first: a clean install doesn't hold them, and the enable
  /// intent is rejected with a SecurityException without BLUETOOTH_CONNECT.
  /// Throws when permissions are denied; a dismissed enable dialog completes
  /// normally with the radio still off.
  Future<void> _requestEnableBluetooth() async {
    if (kIsWeb) return;
    await UniversalBle.requestPermissions();
    if (BleCapabilities.supportsBluetoothEnableApi) {
      await UniversalBle.enableBluetooth(timeout: _enableDialogTimeout);
    }
    await _updateBluetoothState();
  }

  void _onScanResult(BleDevice result) {
    // Plain ADV packets often omit the name (it may only ride in the
    // SCAN_RSP) and some stacks deliver each PDU as a separate callback, so a
    // nameless re-advertisement must not blank the row title.
    final existingIdx = _devices.indexWhere(
      (d) => d.deviceId == result.deviceId,
    );
    final mapped = DiscoveredDevice(
      deviceId: result.deviceId,
      name:
          result.name ?? (existingIdx >= 0 ? _devices[existingIdx].name : null),
      rssi: result.rssi,
      timestamp: result.timestamp,
    );
    if (existingIdx >= 0) {
      _devices[existingIdx] = mapped;
    } else {
      _devices.add(mapped);
    }
    // A re-discovered device is a fresh platform handle.
    _connectFailures.remove(mapped.deviceId);
    notifyListeners();
    _syncFreshnessPoke();
    // Web: the "scan" is Chrome's requestDevice() picker; the one result is
    // the device the user just picked.
    if (kIsWeb) {
      unawaited(_connectPickedWebDevice(mapped));
    }
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = BtAvailability.values.byName(state.name);
    if (_bluetoothState == BtAvailability.poweredOff) {
      _isScanning = false;
      _devices.clear();
    }
    notifyListeners();
    _syncFreshnessPoke();
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != BtAvailability.poweredOn) {
      await _requestEnableBluetooth();
      if (_bluetoothState != BtAvailability.poweredOn) {
        return;
      }
    }
    if (_link.state != BtLinkState.idle && !_link.isStreaming) {
      return;
    }
    // TODO(ux): starting a scan while streaming disconnects the active link
    // — and silently stops any in-progress recording. Decide the policy:
    // disable Scan while streaming, or confirm first when a recording is in
    // progress. (The Devices tab Scan button mirrors this TODO.)
    await disconnectSelectedDevice();
    // On web startScan is the requestDevice() picker and yields exactly one
    // result; previously picked devices stay connectable (their handles live
    // in universal_ble's device map for the page session), so they are kept.
    final previousDevices = List<DiscoveredDevice>.of(_devices);
    if (!kIsWeb) {
      _devices.clear();
    }
    _isScanning = true;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [btServiceId]),
        platformConfig: PlatformConfig(
          // Web Bluetooth gates GATT access per service: anything touched
          // over GATT beyond the picker-filter service must be declared here.
          web: WebOptions(
            optionalServices: [btServiceId, btSvcDeviceInfo, otaServiceId],
          ),
        ),
      );
    } catch (e) {
      // Plain catch: the web picker errors are Errors, not Exceptions.
      _isScanning = false;
      _devices
        ..clear()
        ..addAll(previousDevices);
      notifyListeners();
      if (kIsWeb && isWebPickerDismissal(e)) {
        debugPrint('Web scan picker closed without a selection: $e');
        return;
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> toggleScan() async {
    if (_isScanning) {
      await _stopScan();
    } else {
      await _startScan();
    }
  }

  /// Only fires on Android (API 26+); universal_ble only calls
  /// updateConnectionParameters from its native (pigeon) channel, so web
  /// never emits these.
  void _onConnectionParametersChange(BleConnectionParametersUpdated update) {
    if (_link.deviceId.isNotEmpty && _link.deviceId != update.deviceId) {
      return;
    }
    debugPrint(
      'connParams ${update.deviceId}: '
      'interval=${update.intervalMs}ms, '
      'latency=${update.latency}, '
      'supervisionTimeout=${update.supervisionTimeoutMs}ms, '
      'estimatedPriority=${update.estimatedPriority}, '
      'success=${update.isSuccess}',
    );
  }

  void _startRssiPolling(LinkTransport transport) {
    _stopRssiPolling();
    if (transport.isSimulated || !_supportsRssi) {
      return;
    }
    _rssiPollTimer = Timer.periodic(rssiPollInterval, (_) async {
      if (!identical(_link.transport, transport) || !_link.isStreaming) {
        _stopRssiPolling();
        return;
      }
      try {
        final int rssi = await transport.readRssi();
        if (identical(_link.transport, transport) && _link.isStreaming) {
          _link.telemetry?.rssi = rssi;
          notifyListeners();
        }
      } catch (_) {
        // Next tick retries.
      }
    });
  }

  void _stopRssiPolling() {
    _rssiPollTimer?.cancel();
    _rssiPollTimer = null;
  }

  /// [releasePlatform]: the platform link is (or may still be) up, so it is
  /// disconnected best-effort. Local state is reset FIRST, so the resulting
  /// callback finds an unwanted link and is ignored (see
  /// [_onConnectionChange]). Does not call [notifyListeners]; callers do.
  void _teardownLink(LinkTransport transport, {bool releasePlatform = false}) {
    final previous = _link;
    _supersedeSetupPasses();
    transport.dispose();
    _stopRssiPolling();

    if (kIsWeb &&
        !transport.isSimulated &&
        previous.state != BtLinkState.connecting) {
      _reconnectNotBefore[transport.deviceId] = DateTime.now().add(
        reconnectSettleDelay,
      );
      _reconnectPoke?.cancel();
      _reconnectPoke = Timer(reconnectSettleDelay, () {
        _reconnectPoke = null;
        notifyListeners();
      });
    }
    _link = const NoLink();

    if (releasePlatform) {
      unawaited(transport.disconnect());
    }
  }

  Future<void> _releaseGatt(String deviceId) async {
    try {
      await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    } catch (_) {
      // Best effort only: the link is unwanted either way.
    }
  }

  void _onConnectionChange(String deviceId, bool isConnected, String? err) {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    // Unwanted-link guard: events for another device, or connected events for
    // OUR device when no link is expected (idle — including inside a pending
    // reconnect-settle window — or closing). A platform-level connect can
    // complete AFTER we gave up on it (connect timeout, user cancel); release
    // such links so they can't leak.
    final bool isActiveDevice =
        _link.deviceId.isNotEmpty && _link.deviceId == deviceId;
    if (!isActiveDevice ||
        (isConnected && _link is! Connecting && !_link.isLinkUp)) {
      if (isConnected) {
        debugPrint('Releasing unexpected GATT link for $deviceId');
        unawaited(_releaseGatt(deviceId));
      } else {
        debugPrint(
          'Ignoring connection change for non-active device $deviceId',
        );
      }
      return;
    }

    if (isConnected) {
      // The connect() continuation owns post-connect setup.
      return;
    }

    // A disconnect event while a connect attempt is in flight is how NATIVE
    // stacks report a REFUSED connect: universal_ble delivers the refusal to
    // this handler synchronously, THEN completes the connect() future with an
    // error from that same event. Record the marker here; the future's error
    // lands in [_beginLink]'s catch, which finds the link already idle and
    // returns silently.
    if (_link is Connecting) {
      _connectFailures[deviceId] = ConnectFailureKind.failed;
      _teardownLink(_link.transport!);
      notifyListeners();
      return;
    }

    final Link link = _link;
    final String name = link.displayName;
    // User-requested disconnects arrive in `disconnecting` (wasActive false);
    // setup failures already emitted BleConnectionFailed.
    final bool wasActive = link.isLinkUp;
    if (wasActive) {
      _stampAlive(deviceId);
      if (err != null && err.isNotEmpty) {
        _lastDisconnectErrors[deviceId] = err;
      } else {
        _lastDisconnectErrors.remove(deviceId);
      }
    }
    _teardownLink(link.transport!);
    if (wasActive) {
      _events.emit(BleConnectionLost(name));
    }
    notifyListeners();
  }

  Future<void> _runPostConnectSetup(
    _SetupToken token,
    LinkTransport transport,
  ) async {
    final String deviceId = transport.deviceId;
    final setup = SettingUp(transport, BtLinkState.connected);
    _link = setup;
    notifyListeners();

    try {
      setup.mtu = await transport.negotiateMtu();
      if (!token.isCurrent) return;

      await transport.discoverServices();
      if (!token.isCurrent) return;

      setup.info = await transport.readDeviceInfo();
      if (!token.isCurrent) return;

      // The KVS channel comes up BEFORE the ADC feed subscription: firmware
      // locks the KVS while the feed holds the device lock.
      setup.phase = BtLinkState.readingConstants;
      notifyListeners();

      final AdcConfig adcConfig = await transport.readAdcConfig();
      if (!token.isCurrent) return;
      setup.adcConfig = adcConfig;
      _onSampleRate(adcConfig.sampleRateHz);

      await transport.openBackend();
      if (!token.isCurrent) return;
      final backend = transport.backend;
      if (backend == null) {
        throw StateError('KVS channel unavailable on $deviceId');
      }
      // The stored name lands before the flash read: the rig's provenance
      // label is read off the link at doc delivery time.
      setup.storedName = await backend.readDeviceName();
      if (!token.isCurrent) return;
      notifyListeners();

      final snapshot = await backend.readKvsSnapshot();
      if (!token.isCurrent) return;
      // A parse failure is a value (InvalidBoardCalibration), not a link
      // failure.
      final flash = DeviceFlash.fromKvs(snapshot, pgaGains: adcConfig.pgaGains);
      onDeviceFlash(flash);

      setup.phase = BtLinkState.subscribing;
      notifyListeners();

      await transport.subscribeToAdcFeed();
      if (!token.isCurrent) return;

      _link = Ready(
        LinkInfo(
          transport: transport,
          advertisedName: transport.displayName,
          storedName: setup.storedName,
          info: setup.info,
          mtu: setup.mtu,
          adcConfig: adcConfig,
          telemetry: setup.telemetry,
        ),
      );
      _stampAlive(deviceId);
      notifyListeners();
      _startRssiPolling(transport);
    } catch (e) {
      if (!token.isCurrent) {
        debugPrint('Ignoring stale post-connect failure for $deviceId: $e');
        return;
      }
      debugPrint('Post-connect setup failed for $deviceId: $e');
      _stampAlive(deviceId);
      _teardownLink(transport, releasePlatform: true);
      _setupFailures[deviceId] = '$e';
      _events.emit(BleConnectionFailed(transport.displayName));
      notifyListeners();
    }
  }

  /// Kept synchronous so callers write their busy state in the same task —
  /// a Scan tap dispatched right after a Connect tap then sees `connecting`
  /// and bails (see [_startScan]).
  bool _beginConnect() {
    if (linkBusy) {
      return false;
    }
    _connectFailures.clear();
    _lastDisconnectErrors.clear();
    _setupFailures.clear();
    _supersedeSetupPasses();
    return true;
  }

  Future<void> _beginLink(LinkTransport transport) async {
    if (!_beginConnect()) return;
    _link = Connecting(transport);
    notifyListeners();

    try {
      // Stop scanning before connecting (the package advises it).
      if (_isScanning) {
        await _stopScan();
      }
      await transport.connect();
    } catch (e) {
      // Already torn down by a cancel, a newer attempt, or a refusal that
      // arrived via [_onConnectionChange] first.
      if (_link is! Connecting || _link.deviceId != transport.deviceId) {
        return;
      }
      _connectFailures[transport.deviceId] = e is TimeoutException
          ? ConnectFailureKind.timeout
          : ConnectFailureKind.failed;
      _teardownLink(transport, releasePlatform: true);
      notifyListeners();
      rethrow;
    }

    // A refusal callback may have torn the attempt down during connect.
    if (_link is! Connecting || _link.deviceId != transport.deviceId) {
      return;
    }
    unawaited(
      _runPostConnectSetup(_setupTokenFor(transport.deviceId), transport),
    );
  }

  Future<void> connectToDemoDevice() async {
    final demo = _demo;
    if (demo == null) {
      throw StateError('connectToDemoDevice with no simulated link wired');
    }
    demo.attachFeedSink(_deliverAdcData);
    await _beginLink(demo);
  }

  Future<void> connectToDevice(String deviceId) async {
    final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
    final transport = BleLinkTransport(
      deviceId: deviceId,
      displayName: device?.name ?? deviceId,
      withFeedPaused: _withFeedPaused,
      connectTimeout: connectTimeout,
      disconnectTimeout: disconnectTimeout,
    );
    await _beginLink(transport);
  }

  Future<void> _connectPickedWebDevice(DiscoveredDevice device) async {
    _reconnectNotBefore.clear();
    _reconnectPoke?.cancel();
    _reconnectPoke = null;
    try {
      await connectToDevice(device.deviceId);
    } catch (e) {
      debugPrint('Auto-connect to ${device.deviceId} failed: $e');
    }
  }

  Future<void> disconnectSelectedDevice() async {
    final Link link = _link;
    final LinkTransport? transport = link.transport;
    if (transport == null) return;
    if (link is! Connecting && !link.isLinkUp) return;
    final String deviceId = transport.deviceId;
    final String deviceName = link.displayName;
    _supersedeSetupPasses();

    // Stamped here, not in the callback: by the time it runs the state is
    // already `disconnecting`, so its `wasActive` check is false.
    if (link.isLinkUp) {
      _stampAlive(deviceId);
    }
    _link = Closing(transport);
    notifyListeners();

    await transport.disconnect();
    // Workaround for a universal_ble bug: its disconnect path can leave the
    // availability stream stale without this extra query.
    if (!transport.isSimulated) {
      await UniversalBle.getBluetoothAvailabilityState();
    }
    if (_link is Closing && _link.deviceId == deviceId) {
      if (!transport.isSimulated) {
        debugPrint('Disconnect did not settle for $deviceId; forcing idle');
      }
      _teardownLink(transport);
      if (!transport.isSimulated) {
        _events.emit(BleDisconnectTimeout(deviceName));
      }
      notifyListeners();
    }
  }

  void _deliverAdcData(Uint8List data) {
    final telemetry = _link.telemetry;
    if (telemetry == null) return;
    final n = data.length;
    final prevMin = telemetry.minAdcPacketBytes;
    final prevMax = telemetry.maxAdcPacketBytes;
    if (prevMin == null || n < prevMin) telemetry.minAdcPacketBytes = n;
    if (prevMax == null || n > prevMax) telemetry.maxAdcPacketBytes = n;
    if (telemetry.minAdcPacketBytes != prevMin ||
        telemetry.maxAdcPacketBytes != prevMax) {
      notifyListeners();
    }
    _onAdcData(data);
  }

  void _onValueChange(
    String deviceId,
    String characteristicId,
    Uint8List data,
    int? timestamp,
  ) {
    // universal_ble normalizes characteristicId to lowercase before invoking
    // this callback, and all ids are already lowercase, so an exact match is
    // safe.
    if (deviceId != _link.deviceId) {
      logTrace(
        () =>
            'Dropping notification from unexpected device $deviceId, '
            'characteristic $characteristicId (${data.length} B); '
            'active link is ${_link.deviceId.isEmpty ? '(none)' : _link.deviceId}',
      );
      return;
    }
    if (characteristicId == btChrAdcFeedId) {
      _deliverAdcData(data);
    } else if (characteristicId == btChrKvs) {
      _link.backend?.handleKvsFrame(data);
    } else if (characteristicId == btChrOtaControl) {
      _link.transport?.handleOtaFrame(data);
    } else {
      logTrace(
        () =>
            'Dropping notification from unexpected characteristic '
            '$characteristicId (${data.length} B)',
      );
    }
  }

  static void _ignoreFeedData(Uint8List data) {}

  static void _ignoreSampleRate(int sampleRateHz) {}

  /// Invoked by the NEXT generation's `main()` via the hot-restart cleanup
  /// hook (see `hot_restart_cleanup_web.dart`): browser-side BLE notification
  /// listeners and timers survive a web hot restart, so without this the old
  /// decoder/DataHub keep running and try to render into the disposed engine
  /// view.
  ///
  /// Order matters: the per-packet data callbacks are silenced FIRST
  /// (synchronously) so the notifyListeners → scheduleFrame chain stops
  /// immediately; the async platform teardown then releases the browser-level
  /// connection so the new generation can reconnect the device.
  Future<void> shutdownForHotRestart() async {
    _onAdcData = _ignoreFeedData;
    _onSampleRate = _ignoreSampleRate;
    final transport = _link.transport;
    transport?.dispose();
    _stopRssiPolling();
    _freshnessPoke?.cancel();
    _freshnessPoke = null;
    _reconnectPoke?.cancel();
    _reconnectPoke = null;
    _supersedeSetupPasses();

    try {
      if (_isScanning) {
        await UniversalBle.stopScan();
      }
      if (transport != null && !transport.isSimulated && _link.isLinkUp) {
        await transport.disconnect();
      }
    } catch (_) {
      // Stale-generation teardown must never surface errors.
    }
  }
}
