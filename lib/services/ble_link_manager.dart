import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'app_events.dart';
import 'bt_device_config.dart';
import 'demo_signal_source.dart';
import 'mockble.dart';
import '../utils/log.dart';

/// Lifecycle of a single device's BLE link.
///
/// This is intentionally a *per-device* concept even though, today, the app
/// only tracks one link at a time (see [DeviceLink] / [BleLinkManager]).
enum BtLinkState {
  /// No connection to this device; it may or may not be in the discovered list.
  idle,

  /// A `connect()` call is outstanding; not yet usable.
  connecting,

  /// The GATT link is up but post-connect setup (service discovery + ADC feed
  /// subscription) is still running. NOT yet usable — no data is flowing. The
  /// UI shows "Setting up…" here. The link advances to [streaming] only once the
  /// ADC feed subscription succeeds, or is torn down on failure.
  connected,

  /// Fully set up: services discovered and the ADC feed subscription is active,
  /// so data is flowing. This is the single "usable / connected" state every
  /// screen keys off — the Devices tab shows "Connected" and the Live tab shows
  /// the graph only in this state.
  streaming,

  /// A `disconnect()` was requested; awaiting the connection callback (or the
  /// disconnect() timeout). Connect must stay blocked while in this state so we
  /// never issue a connect against a half-torn-down link.
  disconnecting,

  /// The link has fully disconnected, but the platform stack (Web Bluetooth on
  /// Chrome in particular) may not yet be ready to accept a fresh connection to
  /// the SAME device. We hold the link here for [BleLinkManager.reconnectSettleDelay]
  /// after teardown so the UI keeps Connect disabled (with a "please wait" hint)
  /// instead of silently sleeping inside the connect call. Web-only; native
  /// stacks go straight back to [idle] on disconnect.
  cooldown,
}

/// All per-device link state for a single BLE device. Everything logically
/// per-device lives here rather than as loose fields on [BleLinkManager] —
/// see the multi-device roadmap on [BleLinkManager].
class DeviceLink {
  DeviceLink({this.deviceId = ''});

  /// Empty string means "no device" (the [BtLinkState.idle] sentinel).
  String deviceId;
  String name = '';
  BtLinkState state = BtLinkState.idle;

  /// Most recent live RSSI (dBm) for the connected device, polled while
  /// connected. Null until the first successful read (and after reset). This is
  /// the *connected* signal strength — distinct from the scan-time RSSI carried
  /// on each discovered [BleDevice].
  int? rssi;

  bool get isConnecting => state == BtLinkState.connecting;

  /// The GATT link is up. True for both the "setting up" ([BtLinkState.connected])
  /// window and the usable ([streaming]) state — use [isStreaming] for "usable".
  bool get isLinkUp =>
      state == BtLinkState.connected || state == BtLinkState.streaming;

  /// The single "usable / connected" truth: link up AND the ADC feed is flowing.
  bool get isStreaming => state == BtLinkState.streaming;
  bool get isDisconnecting => state == BtLinkState.disconnecting;
  bool get isCoolingDown => state == BtLinkState.cooldown;

  /// Reset back to the idle sentinel (used on disconnect).
  void reset() {
    deviceId = '';
    name = '';
    state = BtLinkState.idle;
    rssi = null;
  }

  bool get isDemoDevice => deviceId == 'demo_device';

  /// Like [reset], but parks the link in [BtLinkState.cooldown] for the given
  /// [deviceId] (the device just torn down). Keeps [deviceId]/[name] so the UI
  /// can label that specific device's row while the reconnect settle window
  /// elapses; everything else is cleared as in [reset].
  void enterCooldown(String deviceId, String name) {
    this.deviceId = deviceId;
    this.name = name;
    state = BtLinkState.cooldown;
    rssi = null;
  }
}

/// Cancellation token for one async post-connect setup pass. Captured at pass
/// start; after every `await` the pass checks [isCurrent] and bails silently
/// when false. A token stops being current when the epoch moved on (a newer
/// connect, a disconnect, or any teardown — see
/// [BleLinkManager._supersedeSetupPasses]) or the active link is no longer
/// the token's device. Issuing and checking tokens is the only API, so a pass
/// can never forget to stamp itself.
class _SetupToken {
  const _SetupToken(this._manager, this._epoch, this.deviceId);

  final BleLinkManager _manager;
  final int _epoch;
  final String deviceId;

  bool get isCurrent =>
      _manager._setupEpoch == _epoch && _manager._link.deviceId == deviceId;
}

/// The BLE link state machine: adapter availability, scanning, connect /
/// post-connect setup / disconnect / cooldown, and live RSSI polling.
///
/// This class owns *only* the link. It knows nothing about the wire protocol
/// or recording: raw notification bytes and calibration reads are handed off
/// via [onAdcData] / [onCalibrationData] (wired to [AdcPacketDecoder] at app
/// startup), and recording observes this notifier's state changes (see
/// [RecordingController]).
///
/// MULTI-DEVICE ROADMAP: today exactly one link is tracked ([_link]), and
/// [QueueType.perDevice] already isolates per-device command queues. To
/// support N simultaneous devices, promote [_link] to a
/// `Map<String /*deviceId*/, DeviceLink>`: [DeviceLink] holds every logically
/// per-device field (state, name, rssi), so the migration is mechanical —
/// per-device lookup in [_onConnectionChange] and [_onValueChange] (route by
/// deviceId instead of dropping), per-device busy guards in [_beginConnect]
/// and [disconnectSelectedDevice]. Adapter availability and scanning stay
/// *global* (one radio) and do NOT move into [DeviceLink].
class BleLinkManager extends ChangeNotifier {
  /// Upper bound we pass to [UniversalBle.disconnect] so a silent stack can't
  /// strand the UI on "Disconnecting…". The package's own `disconnect()` sets
  /// up a completer over its connection-event stream and applies this timeout
  /// internally, then drives our [_onConnectionChange] callback (even in the
  /// already-disconnected case), so we no longer hand-roll a parallel Timer.
  static const Duration disconnectTimeout = Duration(milliseconds: 2500);

  /// Upper bound passed to [UniversalBle.connect] so a hung connect attempt
  /// can't strand the UI on "Connecting…". connect() bypasses the package's
  /// command queue — so [UniversalBle.timeout] does NOT cover it — and
  /// defaults to 60 s; 15 s is comfortably past a slow connect or a platform
  /// pairing prompt without feeling wedged. When it fires, the platform
  /// connect may still complete later — that late callback is released and
  /// ignored by the unwanted-link guard in [_onConnectionChange].
  static const Duration connectTimeout = Duration(seconds: 5);

  /// How often to poll the connected device's RSSI for the live signal display.
  static const Duration rssiPollInterval = Duration(seconds: 2);

  /// After a device disconnects, some BLE stacks (notably Web Bluetooth on
  /// Chrome) need a moment to finish tearing down GATT before they will accept
  /// a fresh connection to the SAME device. Reconnecting sooner makes Chrome
  /// briefly accept then drop the link (and throws "Cannot discover services if
  /// the device is not connected"). On web we hold the link in
  /// [BtLinkState.cooldown] for this window after teardown — Connect stays
  /// disabled (with a hint) until it elapses. Web Bluetooth exposes no reliable
  /// teardown signal, so the window is enforced as a timer, not a state query.
  /// Native stacks don't exhibit the race and go straight back to idle.
  static const Duration reconnectSettleDelay = Duration(milliseconds: 4000);

  /// One-shot timer that returns the active link from [BtLinkState.cooldown]
  /// back to [BtLinkState.idle] once [reconnectSettleDelay] has elapsed since
  /// the last teardown. Web-only (see [_teardownLink]). Cancelled if the
  /// link is superseded before it fires.
  Timer? _cooldownTimer;

  /// Epoch counter for the async post-connect setup cancellation tokens (see
  /// [_SetupToken]). Bumped on every connect request, disconnect request, and
  /// teardown via [_supersedeSetupPasses]; async setup code captures a token
  /// and re-checks it after each `await`, bailing out silently when
  /// superseded. This is what stops the "furious clicking" races from
  /// corrupting link state or spamming toasts.
  int _setupEpoch = 0;

  /// Issue a cancellation token for a new setup pass over the current epoch.
  _SetupToken _setupTokenFor(String deviceId) =>
      _SetupToken(this, _setupEpoch, deviceId);

  /// Supersede every outstanding setup pass (a newer connect, a disconnect,
  /// or a teardown happened).
  void _supersedeSetupPasses() => _setupEpoch++;

  AvailabilityState _bluetoothState = AvailabilityState.unknown;
  AvailabilityState get bluetoothState => _bluetoothState;

  final List<BleDevice> _devices = [];
  List<BleDevice> get devices => List.unmodifiable(_devices);

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// The single active device link (see the multi-device roadmap on the
  /// class). The getters below project it into the flat API the UI consumes
  /// today.
  final DeviceLink _link = DeviceLink();
  DeviceLink get link => _link;

  /// The single "usable / connected" truth: link up AND the ADC feed is
  /// streaming. Every screen keys its connected UI off this.
  bool get isStreaming => _link.isStreaming;

  /// The link state as the BLE status readout should see it. The demo device
  /// is not BLE: while it occupies the link slot the BLE link reports
  /// [BtLinkState.idle], so the status falls through to scan/adapter state
  /// instead of claiming "Connected".
  BtLinkState get bleLinkState =>
      _link.isDemoDevice ? BtLinkState.idle : _link.state;

  /// True while a disconnect has been requested but not yet confirmed.
  bool get isDisconnecting => _link.isDisconnecting;

  /// True while the GATT link is up (during post-connect setup or streaming).
  bool get isLinkUp => _link.isLinkUp;

  /// True during the post-disconnect settle window (web only) — the link has
  /// fully torn down but the stack isn't yet ready to reconnect to the same
  /// device. Connect stays blocked while this is true.
  bool get isCoolingDown => _link.isCoolingDown;

  /// A link is "busy" whenever it is mid-transition, active, or cooling down
  /// after a disconnect; device-row Connect buttons stay disabled until the
  /// link returns to idle. This is what prevents the disconnect→reconnect
  /// double-click race — including the web post-disconnect settle window where
  /// the stack isn't yet ready to accept a fresh connection.
  bool get linkBusy => _link.state != BtLinkState.idle;

  /// Device id of the active link whenever the GATT link is up (during setup or
  /// while streaming); empty otherwise.
  String get selectedDeviceId => _link.isLinkUp ? _link.deviceId : '';

  /// Name of the currently connected device.
  String get connectedDeviceName =>
      _link.name.isEmpty ? _link.deviceId : _link.name;

  /// Live RSSI (dBm) of the connected device, or null when not streaming, not
  /// yet read, or unsupported on this platform. Polled every [rssiPollInterval]
  /// while streaming.
  int? get connectedRssi => _link.isStreaming ? _link.rssi : null;

  /// Whether the platform implements [UniversalBle.readRssi]. Web throws
  /// `notImplemented` for it; all native platforms (Android/Apple/Windows/Linux)
  /// support it. universal_ble has no dedicated capability flag for RSSI, so we
  /// gate on `!kIsWeb`.
  bool get _supportsRssi => !kIsWeb;

  /// Periodic poller for [connectedRssi]; runs only while a link is streaming
  /// AND the surface displaying RSSI (the Devices tab) is visible.
  Timer? _rssiPollTimer;

  /// Whether the surface displaying live RSSI (the Devices tab's connected
  /// card) is currently visible. Polling runs only while this is true and a
  /// link is streaming: off-screen RSSI reads would wake the radio every
  /// [rssiPollInterval] for nothing.
  bool _rssiUiActive = false;

  /// Called by the shell when the RSSI-displaying tab becomes visible/hidden.
  void setRssiUiActive(bool active) {
    if (_rssiUiActive == active) return;
    _rssiUiActive = active;
    if (!active) {
      _stopRssiPolling();
    } else if (_link.isStreaming) {
      _startRssiPolling(_link.deviceId);
    }
  }

  /// Raw ADC-feed notification bytes, exactly as received. Wired to the
  /// protocol layer ([AdcPacketDecoder.onDataPacket]) at app startup; the link
  /// manager itself never interprets them.
  void Function(Uint8List data)? onAdcData;

  /// Raw bytes of the calibration characteristic, read once during post-connect
  /// setup. Wired to [AdcPacketDecoder.onCalibrationPacket] at app startup.
  void Function(Uint8List data)? onCalibrationData;

  /// One-shot user notices ([BleDisconnectTimeout], [BleConnectionFailed])
  /// go here; the shell shows them regardless of which tab is mounted.
  final AppEvents _events;

  DemoSignalSource? _demoSource;

  BleLinkManager({required AppEvents events}) : _events = events {
    if (useMockBt) {
      UniversalBle.setInstance(MockBlePlatform.instance);
    }
    // Run each device's BLE commands in its own queue. With the default
    // `global` queue, a command stuck against a half-torn-down device (common on
    // web when the user rapidly connects/disconnects) blocks and serially times
    // out every later command — producing a storm of 10s "Future not completed"
    // failures. `perDevice` isolates a dead device's stuck commands from a fresh
    // attempt (and is the shape the multi-device roadmap needs).
    UniversalBle.queueType = QueueType.perDevice;
    // Fail stuck commands faster than the 10s default so a hung web GATT promise
    // surfaces (and our generation guard / teardown proceeds) without a long
    // visible stall.
    UniversalBle.timeout = const Duration(seconds: 5);
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onConnectionParametersChange = _onConnectionParametersChange;
    UniversalBle.onValueChange = _onValueChange;

    unawaited(_updateBluetoothState());
  }

  Future<void> _updateBluetoothState() async {
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    notifyListeners();
  }

  /// Request the system to enable Bluetooth (e.g. pop the permission/enable dialog).
  Future<void> requestEnableBluetooth() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth();
      await _updateBluetoothState();
    }
  }

  void _onScanResult(BleDevice newDevice) {
    // Keep all discovered devices; a repeat advertisement from a known device
    // always replaces the stored entry so the row shows the FRESHEST RSSI —
    // signal may weaken as well as strengthen (a null RSSI is kept as-is and
    // the UI shows an honest "RSSI: --"). The one exception is the name:
    // plain ADV packets often omit it (it may only ride in the SCAN_RSP) and
    // some stacks deliver each PDU as a separate callback, so a nameless
    // re-advertisement must not blank the row title — keep the last known
    // name in that case.
    //
    // TODO(firmware): once the device advertises manufacturer data, parse
    // `newDevice.manufacturerDataList` (companyId + payload) into a device model
    // (e.g. "K3 Sampler Pro") and hardware variant (V1/V2) and surface them on
    // the device row / connected card. `serviceData` and `services` are also
    // available here for filtering. Not wired yet — firmware doesn't emit it.
    final existingIdx = _devices.indexWhere(
      (d) => d.deviceId == newDevice.deviceId,
    );
    if (existingIdx >= 0) {
      newDevice.name ??= _devices[existingIdx].name;
      _devices[existingIdx] = newDevice;
    } else {
      _devices.add(newDevice);
    }
    notifyListeners();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
    if (state == AvailabilityState.poweredOff) {
      _isScanning = false;
      _devices.clear();
    }
    notifyListeners();
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    // Guard before any destructive clears: if we can't/shouldn't start a scan,
    // don't wipe the existing device list (which would leave the UI showing an
    // empty list with no picker having opened).
    if (_link.state != BtLinkState.idle && !_link.isStreaming) {
      return;
    }
    // TODO(ux): starting a scan while streaming disconnects the active link
    // — and silently stops any in-progress recording. Decide the policy:
    // disable Scan while streaming, or confirm first when a recording is in
    // progress. (The Devices tab Scan button mirrors this TODO.)
    await disconnectSelectedDevice();
    _devices.clear();
    _isScanning = true;
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [btServiceId]),
      platformConfig: PlatformConfig(
        web: WebOptions(optionalServices: [btServiceId]),
      ),
    );
    notifyListeners();
  }

  Future<void> toggleScan() async {
    if (_isScanning) {
      await _stopScan();
    } else {
      await _startScan();
    }
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  /// Live connection-parameter updates. Only fires on Android (API 26+); a
  /// no-op on every other platform (see [BleCapabilities.supportsConnectionParametersUpdates]).
  /// In particular, the web platform never emits these — universal_ble only
  /// calls updateConnectionParameters from its native (pigeon) channel — so the
  /// absence of these logs on web is expected, not a bug.
  /// Diagnostic only for now — surfaced via debugPrint rather than the UI.
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

  /// Begin polling the connected device's RSSI for the signal display.
  /// No-op on platforms that don't implement readRssi (e.g. web) and while
  /// the RSSI-displaying surface is off-screen (see [setRssiUiActive]).
  /// Cancels any previous poller first. Reads are best-effort: a failed read
  /// is swallowed silently and retried on the next tick (no per-tick logging
  /// — it would spam the console).
  void _startRssiPolling(String deviceId) {
    _stopRssiPolling();
    if (!_supportsRssi || !_rssiUiActive) {
      return;
    }
    _rssiPollTimer = Timer.periodic(rssiPollInterval, (_) async {
      // Stop polling if the link is no longer streaming this device.
      if (!_link.isStreaming || _link.deviceId != deviceId) {
        _stopRssiPolling();
        return;
      }
      try {
        final int rssi = await UniversalBle.readRssi(deviceId);
        // Guard again: the link may have changed during the await.
        if (_link.isStreaming && _link.deviceId == deviceId) {
          _link.rssi = rssi;
          notifyListeners();
        }
      } catch (_) {
        // Swallow: transient read failures are expected; the next tick retries.
      }
    });
  }

  void _stopRssiPolling() {
    _rssiPollTimer?.cancel();
    _rssiPollTimer = null;
  }

  /// Common teardown for every path that ends a link (clean disconnect, failed
  /// post-connect setup, disconnect timeout, abandoned connect): stop RSSI
  /// polling, supersede in-flight setup, and clear the link. Recording is NOT
  /// handled here — [RecordingController] observes this notifier and stops its
  /// session when streaming ends.
  ///
  /// [releaseGatt] must be true when the platform-level GATT link is (or may
  /// still be) up: a failed post-connect setup, or an abandoned/timed-out
  /// connect. It triggers a best-effort [UniversalBle.disconnect] so the
  /// OS/browser connection can't leak. Local state is reset FIRST, so the
  /// resulting disconnect callback arrives to an unwanted link and is ignored
  /// by the guard in [_onConnectionChange].
  ///
  /// On web (real BLE devices only) the link is NOT returned straight to
  /// [BtLinkState.idle]: it is parked in [BtLinkState.cooldown] for
  /// [reconnectSettleDelay] so the UI keeps Connect disabled (with a hint)
  /// until Chrome has finished GATT teardown. Native stacks and the demo
  /// device don't exhibit the too-soon-reconnect race, so they reset directly
  /// to idle. Does NOT call [notifyListeners] — callers do.
  void _teardownLink(String deviceId, String name, {bool releaseGatt = false}) {
    // Supersede any in-flight post-connect setup pass so it bails out instead of
    // writing state for a link we're tearing down.
    _supersedeSetupPasses();
    _stopRssiPolling();
    _cooldownTimer?.cancel();
    _cooldownTimer = null;

    // Cooldown applies to real BLE links on web only — not native, not demo.
    if (!kIsWeb || _link.isDemoDevice) {
      _link.reset();
    } else {
      // Web: hold the link in cooldown for the settle window, then release it.
      _link.enterCooldown(deviceId, name);
      _cooldownTimer = Timer(reconnectSettleDelay, () {
        _cooldownTimer = null;
        // Only release if we're still cooling down THIS device (a new connect
        // attempt to a different device, or a fresh teardown, may have moved on).
        if (_link.isCoolingDown && _link.deviceId == deviceId) {
          _link.reset();
          notifyListeners();
        }
      });
    }

    if (releaseGatt) {
      unawaited(_releaseGatt(deviceId));
    }
  }

  /// Best-effort release of a platform-level GATT link that has no app-side
  /// owner (a timed-out/cancelled connect that later completes, or a link
  /// whose post-connect setup failed). Fire-and-forget: the resulting
  /// connection-change callback arrives to find the link unwanted and is
  /// ignored by the guard in [_onConnectionChange]. Errors are swallowed —
  /// this runs on teardown paths that must never throw.
  Future<void> _releaseGatt(String deviceId) async {
    try {
      await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    } catch (_) {
      // Best effort only: the link is unwanted either way.
    }
  }

  void _onConnectionChange(
    String deviceId,
    bool isConnected,
    String? err,
  ) async {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    // Unwanted-link guard: ignore any connection event that has no app-side
    // owner — events for a different device than the active link, or events
    // for OUR device arriving when no connect result is expected (idle,
    // cooldown, disconnecting). A platform-level connect can complete AFTER
    // we gave up on it (connect timeout, user cancel); the GATT link is then
    // live at the platform level with nothing tracking it. Release such links
    // so they can't leak, then ignore the event.
    final bool isActiveDevice =
        _link.deviceId.isNotEmpty && _link.deviceId == deviceId;
    if (!isActiveDevice ||
        (isConnected && !_link.isConnecting && !_link.isLinkUp)) {
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
      // Capture a cancellation token for this setup pass. Every connect/
      // disconnect/teardown supersedes outstanding tokens (see
      // [_supersedeSetupPasses]); after every await below we re-check it and
      // abandon the pass silently — no state writes, no failure toast — when
      // a newer attempt (or a teardown) moved on.
      final token = _setupTokenFor(deviceId);

      _link.deviceId = deviceId;
      _link.state = BtLinkState.connected; // "Setting up…" until streaming.

      // Store the device name
      final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
      _link.name = device?.name ?? deviceId;

      // Reflect "Setting up…" in the UI immediately, BEFORE the awaited setup
      // work below. Otherwise the label stays on "Connecting…" until discovery
      // finishes (and never updates at all if discovery throws).
      notifyListeners();

      // Post-connect setup. If the device drops mid-setup (common when Chrome
      // accepts a too-soon reconnect then tears it down), these calls throw
      // ("Cannot discover services…") or time out via the command queue.
      try {
        if (!kIsWeb) {
          debugPrint('Requested MTU change');
          final int mtu = await UniversalBle.requestMtu(deviceId, 247);
          debugPrint('MTU set to: $mtu');
          if (!token.isCurrent) return;
          // TODO(perf): investigate requesting high-performance connection
          // priority here for the 1 kHz ADC stream:
          //   await UniversalBle.requestConnectionPriority(
          //     deviceId, BleConnectionPriority.highPerformance);
          // Android-only (BleCapabilities.supportsConnectionPriorityApi); throws
          // notSupported elsewhere. Should run after MTU negotiation. Measure
          // whether the tighter connection interval actually reduces dropped
          // samples before enabling.
        }
        final discovered = await UniversalBle.discoverServices(deviceId);
        if (!token.isCurrent) return;
        bool subscribed = false;
        for (final srv in discovered) {
          if (srv.uuid == btServiceId) {
            subscribed = await subscribeToAdcFeed(srv);
            if (!token.isCurrent) return;
            break;
          }
        }
        // A link without the ADC feed is unusable: fail the connection here
        // (the catch below tears down and toasts) rather than advancing to
        // "streaming" with no data flowing.
        if (!subscribed) {
          throw StateError('ADC feed characteristic not found on $deviceId');
        }
        // Setup complete: advance to the usable "streaming" state and begin live
        // RSSI polling for the signal display.
        _link.state = BtLinkState.streaming;
        notifyListeners();
        _startRssiPolling(deviceId);
      } catch (e) {
        // A superseded pass failing is expected (the device was torn down or a
        // queued command was cancelled/timed out) — swallow it silently. Only a
        // genuine failure of the *current* attempt resets the link and toasts.
        if (!token.isCurrent) {
          debugPrint('Ignoring stale post-connect failure for $deviceId: $e');
          return;
        }
        debugPrint('Post-connect setup failed for $deviceId: $e');
        final String name = _link.name.isEmpty ? deviceId : _link.name;
        // The GATT link came up (connect succeeded) — release it so the
        // platform can't hold a connection the app considers failed.
        _teardownLink(deviceId, name, releaseGatt: true);
        _events.emit(BleConnectionFailed(name));
        notifyListeners();
      }
    } else {
      // A disconnect callback for an already-idle link (e.g. a late event
      // from a previously torn-down connection): nothing to tear down, and
      // running teardown would park a phantom cooldown for a device nobody
      // is connected to.
      if (_link.deviceId.isEmpty) return;

      // Disconnect resolved (whether user-requested or unexpected): run the
      // common teardown (the platform side is already down, so no GATT
      // release), which (on web) parks the link in cooldown for the
      // reconnect settle window before returning it to the idle sentinel.
      final String name = _link.name.isEmpty ? deviceId : _link.name;
      // An unexpected drop while the link was up (setting up or streaming)
      // gets a user notice. User-requested disconnects arrive here in
      // `disconnecting`, and post-connect setup failures already emitted
      // BleConnectionFailed before tearing down — so neither double-reports.
      final bool wasActive =
          _link.state == BtLinkState.connected ||
          _link.state == BtLinkState.streaming;
      _teardownLink(deviceId, name);
      if (wasActive) {
        _events.emit(BleConnectionLost(name));
      }
      notifyListeners();
    }
  }

  /// Synchronous part of the connect preamble: refuse while a link is
  /// mid-transition (the device row's Connect button is disabled until the
  /// link returns to idle — first via the disconnect callback or the
  /// disconnect() timeout reconciliation, then through the post-disconnect
  /// cooldown window on web — so we never start a connect against a link the
  /// stack isn't ready for), cancel a now-moot pending cooldown timer, and
  /// supersede any lingering setup pass from a prior attempt.
  ///
  /// Kept synchronous so callers write their busy state in the same task —
  /// a Scan tap dispatched right after a Connect tap then sees `connecting`
  /// and bails (see [_startScan]).
  ///
  /// NOTE: we deliberately track link state from the event callbacks
  /// (_onConnectionChange) rather than from UniversalBle.getConnectionState().
  /// The latter is a one-shot async *query*, not an event source — it can't
  /// push updates, so it can't replace callback-driven state without polling
  /// (just a different timer).
  bool _beginConnect() {
    if (_link.state != BtLinkState.idle) {
      return false;
    }
    // A pending cooldown timer (from a prior teardown) is now moot: its guard
    // would no-op once we move to `connecting`, but cancel it eagerly so it
    // can't fire against this new attempt.
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _supersedeSetupPasses();
    return true;
  }

  Future<void> connectToDemoDevice() async {
    if (!_beginConnect()) return;
    _link.deviceId = 'demo_device';
    _link.name = 'Demo Device';
    _link.state = BtLinkState.streaming;

    _demoSource ??= DemoSignalSource();
    _demoSource?.start((data) {
      onAdcData?.call(data);
    });

    notifyListeners();
    if (_isScanning) await _stopScan();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (!_beginConnect()) return;
    _link.deviceId = deviceId;
    _link.state = BtLinkState.connecting;
    notifyListeners();

    // Stop scanning before connecting (the package advises it). The busy
    // state is already written above, so this await can't reopen the
    // Scan-tap race.
    if (_isScanning) {
      await _stopScan();
    }

    // The post-disconnect settle window is enforced as the visible
    // [BtLinkState.cooldown] state (see [_teardownLink]) BEFORE Connect is
    // re-enabled, so by the time we get here the stack has already had time
    // to finish GATT teardown. No inline sleep is needed.

    try {
      // connect() bypasses the package command queue and defaults to a 60 s
      // timeout — pass ours explicitly (see [connectTimeout]).
      await UniversalBle.connect(deviceId, timeout: connectTimeout);
    } catch (e) {
      // This attempt was abandoned while its future was outstanding (user
      // cancel, or superseded by a newer one): the teardown already ran, so
      // fail quietly instead of running a second teardown (which would park
      // a phantom cooldown on web) or toasting an error the user asked for.
      if (_link.deviceId != deviceId || !_link.isConnecting) {
        return;
      }
      // Connection result (success) arrives via _onConnectionChange; on a
      // failed connect attempt that callback may never fire, so tear the link
      // down here and let the caller surface the error. Go through the common
      // [_teardownLink] (not a bare reset): it supersedes any lingering
      // setup pass, releases the platform GATT link (a timed-out connect can
      // still complete later — the guard in [_onConnectionChange] handles
      // that callback), and, on web, parks the link in cooldown so an
      // immediate retry doesn't hit the too-soon-reconnect race.
      final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
      _teardownLink(deviceId, device?.name ?? deviceId, releaseGatt: true);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnectSelectedDevice() async {
    // Allow disconnecting whenever a link attempt is in flight or the GATT
    // link is up — connecting (cancel a stuck/hung attempt), connected
    // (cancel a stuck setup), or streaming. The teardown releases the
    // platform side; a connect that completes after we gave up on it is
    // caught by the unwanted-link guard in [_onConnectionChange].
    if (!_link.isConnecting && !_link.isLinkUp) {
      return;
    }
    final String deviceId = _link.deviceId;
    final String deviceName = _link.name.isEmpty ? deviceId : _link.name;
    // Supersede any in-flight post-connect setup pass immediately so it stops
    // mutating state while we tear the link down.
    _supersedeSetupPasses();

    if (_link.isDemoDevice) {
      _demoSource?.stop();
      _teardownLink(_link.deviceId, _link.name);
      notifyListeners();
      return;
    }

    _link.state = BtLinkState.disconnecting;
    notifyListeners();

    // Option B: lean on the package's own disconnect() instead of a parallel
    // safety Timer. UniversalBle.disconnect() sets up a completer over its
    // connection-event stream, applies [disconnectTimeout], and — even when the
    // device is already gone — calls updateConnection(deviceId, false), which
    // drives our [_onConnectionChange] handler. That handler is the single place
    // the link is reset to idle, so on a clean disconnect we simply await here
    // and the callback does the work.
    //
    // The returned future is opaque (disconnect() swallows its own errors), so
    // it can't tell us clean-vs-timeout. After it resolves we do one cheap
    // reconciliation: if the link is still stuck in `disconnecting` on this
    // device, the callback never landed within the window — force it idle and
    // surface the "didn't disconnect cleanly" notice ourselves.
    await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle

    if (_link.deviceId == deviceId &&
        _link.state == BtLinkState.disconnecting) {
      debugPrint('Disconnect did not settle for $deviceId; forcing idle');
      // No GATT release here: the disconnect above already went out to the
      // platform; a late callback is handled by the unwanted-link guard.
      _teardownLink(deviceId, deviceName);
      _events.emit(BleDisconnectTimeout(deviceName));
      notifyListeners();
    }
  }

  /// Subscribe to the ADC feed characteristic of [service] (reading the
  /// calibration characteristic first). Returns true when the subscription
  /// was made; false when no usable ADC feed characteristic exists — the
  /// caller fails the connection in that case, since a link without the
  /// feed is unusable.
  Future<bool> subscribeToAdcFeed(BleService service) async {
    final String deviceId = _link.deviceId;
    if (deviceId.isEmpty) {
      return false;
    }
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid != btChrAdcFeedId ||
          !characteristic.properties.contains(CharacteristicProperty.notify)) {
        continue;
      }
      // Calibration is best-effort: parsing is a TODO and defaults are in
      // use, so a failed read must not fail the whole connection.
      // TODO(cal): once real calibration parsing lands, surface a
      // "calibration unreadable — using defaults" warning event instead of
      // only logging.
      try {
        onCalibrationData?.call(
          await UniversalBle.read(deviceId, service.uuid, btChrCalibration),
        );
      } catch (e) {
        debugPrint('Calibration read failed for $deviceId: $e');
      }
      await UniversalBle.subscribeNotifications(
        deviceId,
        service.uuid,
        characteristic.uuid,
      );
      // The link's transition to the usable [BtLinkState.streaming] state is
      // driven by the caller ([_onConnectionChange]) once this returns and the
      // generation guard confirms the pass wasn't superseded.
      return true;
    }
    return false;
  }

  void _onValueChange(
    String deviceId,
    String characteristicId,
    Uint8List data,
    int? timestamp,
  ) {
    // The ADC feed of the active link is the only subscription; drop anything
    // else (a stale notification from a torn-down link, or a second notifying
    // characteristic subscribed in the future) so foreign bytes are never
    // parsed as ADC packets. universal_ble normalizes characteristicId to
    // lowercase before invoking this callback, and btChrAdcFeedId is already
    // lowercase, so an exact match is safe.
    // Multi-device: route by deviceId instead of dropping.
    if (deviceId != _link.deviceId || characteristicId != btChrAdcFeedId) {
      logTrace(
        () =>
            'Dropping notification from unexpected source: device $deviceId, '
            'characteristic $characteristicId (${data.length} B); '
            'active link is ${_link.deviceId.isEmpty ? '(none)' : _link.deviceId}',
      );
      return;
    }
    // Hand the raw packet straight to the protocol layer; the link manager
    // never interprets feed bytes itself.
    onAdcData?.call(data);
  }

  /// Tear down this (now stale) generation's BLE link after a hot restart on
  /// web. Invoked by the NEXT generation's `main()` via the hot-restart
  /// cleanup hook (see `hot_restart_cleanup_web.dart`) — browser-side BLE
  /// notification listeners and timers survive a web hot restart, so without
  /// this the old decoder/DataHub keep running and try to render into the
  /// disposed engine view.
  ///
  /// Order matters: the data callbacks are nulled FIRST (synchronously) so the
  /// notifyListeners → scheduleFrame chain stops immediately; the async GATT
  /// teardown then releases the browser-level connection so the new generation
  /// can find and reconnect the device. Deliberately does NOT call
  /// [notifyListeners] — the only listeners are the disposed widget tree.
  Future<void> shutdownForHotRestart() async {
    onAdcData = null;
    onCalibrationData = null;
    _demoSource?.stop();
    _stopRssiPolling();
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    // Supersede any in-flight post-connect setup pass so it bails out.
    _supersedeSetupPasses();

    // Best-effort from here: the app is being torn down, so failures are
    // irrelevant — just make sure they can't propagate.
    try {
      if (_isScanning) {
        await UniversalBle.stopScan();
      }
      if (_link.isLinkUp && !_link.isDemoDevice) {
        await UniversalBle.disconnect(
          _link.deviceId,
          timeout: disconnectTimeout,
        );
      }
    } catch (_) {
      // Swallow: stale-generation teardown must never surface errors.
    }
  }
}
