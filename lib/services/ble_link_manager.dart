import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'app_events.dart';
import 'bt_device_config.dart';
import 'demo_signal_source.dart';
import 'mockble.dart';

/// Lifecycle of a single device's BLE link.
///
/// This is intentionally a *per-device* concept even though, today, the app
/// only tracks one link at a time (see [DeviceLink] / [BleLinkManager]).
///
/// MULTI-DEVICE (Path A): when we support N simultaneous devices, this enum
/// stays exactly as-is. The only change is that [BleLinkManager] will hold a
/// `Map<String /*deviceId*/, DeviceLink>` instead of the single [_link] below,
/// and the UI will read each row's state from its own [DeviceLink]. The
/// adapter-availability and scanning state remain *global* (one radio), so they
/// do NOT move into [DeviceLink].
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

/// All per-device link state for a single BLE device.
///
/// MULTI-DEVICE (Path A): promote the single [BleLinkManager._link] to a
/// `Map<String, DeviceLink>` keyed by [deviceId]. Each map entry owns its own
/// state/name/services/subscription. The migration is mechanical because
/// every field that is logically per-device already lives here rather than as a
/// loose field on [BleLinkManager].
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

/// The BLE link state machine: adapter availability, scanning, connect /
/// post-connect setup / disconnect / cooldown, and live RSSI polling.
///
/// This class owns *only* the link. It knows nothing about the wire protocol
/// or recording: raw notification bytes and calibration reads are handed off
/// via [onAdcData] / [onCalibrationData] (wired to [AdcPacketDecoder] at app
/// startup), and recording observes this notifier's state changes (see
/// [RecordingController]).
class BleLinkManager extends ChangeNotifier {
  /// Upper bound we pass to [UniversalBle.disconnect] so a silent stack can't
  /// strand the UI on "Disconnecting…". The package's own `disconnect()` sets
  /// up a completer over its connection-event stream and applies this timeout
  /// internally, then drives our [_onConnectionChange] callback (even in the
  /// already-disconnected case), so we no longer hand-roll a parallel Timer.
  static const Duration disconnectTimeout = Duration(milliseconds: 2500);

  /// How often to poll the connected device's RSSI for the live signal display.
  static const Duration rssiPollInterval = Duration(seconds: 2);

  /// After a device disconnects, some BLE stacks (notably Web Bluetooth on
  /// Chrome) need a moment to finish tearing down GATT before they will accept
  /// a fresh connection to the SAME device. Reconnecting sooner makes Chrome
  /// briefly accept then drop the link (and throws "Cannot discover services if
  /// the device is not connected"). On web we hold the link in
  /// [BtLinkState.cooldown] for this window after teardown — Connect stays
  /// disabled (with a hint) until it elapses, instead of silently sleeping
  /// inside [connectToDevice].
  static const Duration reconnectSettleDelay = Duration(milliseconds: 1000);

  /// Timestamp of the last observed disconnect, keyed by deviceId. Kept on the
  /// manager (not on [DeviceLink], which gets reset on disconnect) so the
  /// settle window survives the reset.
  ///
  /// MULTI-DEVICE (Path A): already per-device via this map.
  final Map<String, DateTime> _lastDisconnectAt = {};

  /// One-shot timer that returns the active link from [BtLinkState.cooldown]
  /// back to [BtLinkState.idle] once [reconnectSettleDelay] has elapsed since
  /// the last teardown. Web-only (see [_endLink]). Cancelled if the
  /// link is superseded before it fires.
  Timer? _cooldownTimer;

  /// Monotonic counter bumped on every connect request, disconnect request, and
  /// teardown. The async post-connect setup in [_onConnectionChange] captures
  /// the value at its start and re-checks it after each `await`; if it changed,
  /// a newer connect/disconnect superseded this setup pass, so it bails out
  /// silently (no state writes, no failure toast). This is what stops the
  /// "furious clicking" races from corrupting link state or spamming toasts.
  int _setupGeneration = 0;

  AvailabilityState _bluetoothState = AvailabilityState.unknown;
  AvailabilityState get bluetoothState => _bluetoothState;

  final List<BleDevice> _devices = [];
  List<BleDevice> get devices => _devices;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// The single active device link.
  ///
  /// MULTI-DEVICE (Path A): replace with
  /// `final Map<String, DeviceLink> _links = {};` and add per-device accessors.
  /// The getters below currently project this single link into the flat API the
  /// UI consumes today; in the multi-device world the UI will read each
  /// [DeviceLink] directly instead of via these singular getters.
  final DeviceLink _link = DeviceLink();
  DeviceLink get link => _link;

  /// The single "usable / connected" truth: link up AND the ADC feed is
  /// streaming. Every screen keys its connected UI off this.
  bool get isStreaming => _link.isStreaming;

  /// True while a disconnect has been requested but not yet confirmed.
  bool get isDisconnecting => _link.isDisconnecting;

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

  /// Periodic poller for [connectedRssi]; runs only while a link is connected
  /// and the platform supports RSSI reads.
  Timer? _rssiPollTimer;

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
    // attempt, and aligns with the multi-device roadmap (Path A).
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
    //
    // MULTI-DEVICE (Path A): this becomes "if any link is mid-transition"
    // (connecting/disconnecting/cooldown) rather than a single flag.
    if (_link.isConnecting ||
        _link.isDisconnecting ||
        _link.isCoolingDown ||
        _link.state == BtLinkState.connected) {
      return;
    }
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

  /// Begin polling the connected device's RSSI for the live signal display.
  /// No-op on platforms that don't implement readRssi (e.g. web). Cancels any
  /// previous poller first. Reads are best-effort: a failed read is swallowed
  /// silently and retried on the next tick (no per-tick logging — it would spam
  /// the console).
  void _startRssiPolling(String deviceId) {
    _stopRssiPolling();
    if (!_supportsRssi) {
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
  /// post-connect setup, disconnect timeout): stop RSSI polling, stamp the
  /// disconnect time, and clear the link. Recording is NOT handled here —
  /// [RecordingController] observes this notifier and stops its session when
  /// streaming ends.
  ///
  /// On web we don't go straight to [BtLinkState.idle]: we park the link in
  /// [BtLinkState.cooldown] for the remainder of [reconnectSettleDelay] so the
  /// UI keeps Connect disabled (with a hint) until Chrome has finished GATT
  /// teardown. Native stacks don't exhibit the too-soon-reconnect race, so they
  /// reset directly to idle. Does NOT call [notifyListeners] — callers do.
  void _endLink(String deviceId, String name) {
    // Supersede any in-flight post-connect setup pass so it bails out instead of
    // writing state for a link we're tearing down.
    _setupGeneration++;
    _stopRssiPolling();
    _lastDisconnectAt[deviceId] = DateTime.now();
    _cooldownTimer?.cancel();
    _cooldownTimer = null;

    if (!kIsWeb) {
      _link.reset();
      return;
    }

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

  /// True if the post-connect setup pass that captured [gen] for [deviceId] has
  /// been superseded — i.e. the generation moved on (a newer connect or a
  /// teardown happened) or the active link is no longer this device. Setup code
  /// calls this after each await and bails out silently when true.
  bool _setupSuperseded(int gen, String deviceId) =>
      gen != _setupGeneration || _link.deviceId != deviceId;

  void _onConnectionChange(
    String deviceId,
    bool isConnected,
    String? err,
  ) async {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    // MULTI-DEVICE (Path A): look up `_links[deviceId]` instead of assuming the
    // event is for the single active link. For now we only track one link, so a
    // callback for a different deviceId is ignored.
    if (_link.deviceId.isNotEmpty && _link.deviceId != deviceId) {
      debugPrint('Ignoring connection change for non-active device $deviceId');
      return;
    }

    if (isConnected) {
      // Capture the generation for this setup pass. Every connect/disconnect/
      // teardown bumps [_setupGeneration]; if it changes under us (user clicked
      // again, the device dropped, etc.) we abandon this pass without touching
      // state or surfacing a toast — see [_setupSuperseded].
      final int gen = ++_setupGeneration;

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
      // ("Cannot discover services…") or time out via the command queue. We
      // re-check the generation after every await: if superseded, bail silently
      // so a stale pass can't clobber a newer attempt or emit a spurious toast.
      try {
        if (!kIsWeb) {
          debugPrint('Requested MTU change');
          final int mtu = await UniversalBle.requestMtu(deviceId, 247);
          debugPrint('MTU set to: $mtu');
          if (_setupSuperseded(gen, deviceId)) return;
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
        if (_setupSuperseded(gen, deviceId)) return;
        for (final srv in discovered) {
          if (srv.uuid == btServiceId) {
            await subscribeToAdcFeed(srv);
            if (_setupSuperseded(gen, deviceId)) return;
            break;
          }
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
        if (_setupSuperseded(gen, deviceId)) {
          debugPrint('Ignoring stale post-connect failure for $deviceId: $e');
          return;
        }
        debugPrint('Post-connect setup failed for $deviceId: $e');
        final String name = _link.name.isEmpty ? deviceId : _link.name;
        _endLink(deviceId, name);
        _events.emit(BleConnectionFailed(name));
        notifyListeners();
      }
    } else {
      // Disconnect resolved (whether user-requested or unexpected): run the
      // common teardown, which (on web) parks the link in cooldown for the
      // reconnect settle window before returning it to the idle sentinel.
      final String name = _link.name.isEmpty ? deviceId : _link.name;
      _endLink(deviceId, name);
      notifyListeners();
    }
  }

  Future<void> connectToDemoDevice() async {
    if (_isScanning) {
      await _stopScan();
    }
    if (_link.state != BtLinkState.idle) {
      return;
    }
    _setupGeneration++;
    _link.deviceId = 'demo_device';
    _link.name = 'Demo Device';
    _link.state = BtLinkState.streaming;

    _demoSource ??= DemoSignalSource();
    _demoSource?.start((data) {
      onAdcData?.call(data);
    });

    notifyListeners();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await _stopScan();
    }
    // Block connecting while a link is busy (connecting/connected/disconnecting)
    // or cooling down. The disconnecting/cooldown cases are what stop the
    // "double-click after Disconnect" race: the device row's Connect button is
    // disabled until the link returns to idle — first via the disconnect
    // callback (or the disconnect() timeout reconciliation), then through the
    // post-disconnect cooldown window on web — so we never reach here against a
    // link that the stack isn't yet ready to reconnect.
    //
    // NOTE: we deliberately track link state from the event callbacks
    // (_onConnectionChange) rather than from UniversalBle.getConnectionState().
    // The latter is a one-shot async *query*, not an event source — it can't
    // push updates, so it can't replace callback-driven state without polling
    // (just a different timer). It's only worth a one-shot reconciliation call
    // (e.g. on app resume), which we don't need today.
    //
    // MULTI-DEVICE (Path A): this guard becomes per-device — a different,
    // idle device can connect while another is mid-transition.
    if (_link.state != BtLinkState.idle) {
      return;
    }
    // A pending cooldown timer (from a prior teardown) is now moot: its guard
    // would no-op once we move to `connecting`, but cancel it eagerly so it
    // can't fire against this new attempt.
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    // Supersede any lingering setup pass from a prior attempt.
    _setupGeneration++;
    _link.deviceId = deviceId;
    _link.state = BtLinkState.connecting;
    notifyListeners();

    // The post-disconnect settle window is now enforced as the visible
    // [BtLinkState.cooldown] state (see [_endLink]) BEFORE Connect is re-enabled,
    // so by the time we get here the stack has already had time to finish GATT
    // teardown. No inline sleep is needed.

    try {
      await UniversalBle.connect(deviceId);
    } catch (e) {
      // Connection result (success) arrives via _onConnectionChange; on a
      // failed connect attempt that callback may never fire, so reset the
      // link here and let the caller surface the error.
      _link.reset();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnectSelectedDevice() async {
    // Allow disconnecting whenever the GATT link is up — whether still "setting
    // up" or fully streaming — so the user can cancel a stuck setup too.
    if (!_link.isLinkUp) {
      return;
    }
    final String deviceId = _link.deviceId;
    final String deviceName = _link.name.isEmpty ? deviceId : _link.name;
    // Supersede any in-flight post-connect setup pass immediately so it stops
    // mutating state while we tear the link down.
    _setupGeneration++;

    if (_link.isDemoDevice) {
      _demoSource?.stop();
      _endLink(_link.deviceId, _link.name);
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
    //
    // MULTI-DEVICE (Path A): operate on `_links[deviceId]` so each device
    // settles independently and the notice can name that specific device.
    await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle

    if (_link.deviceId == deviceId &&
        _link.state == BtLinkState.disconnecting) {
      debugPrint('Disconnect did not settle for $deviceId; forcing idle');
      _endLink(deviceId, deviceName);
      _events.emit(BleDisconnectTimeout(deviceName));
      notifyListeners();
    }
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    final String deviceId = _link.deviceId;
    if (deviceId.isEmpty) {
      return;
    }
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid != btChrAdcFeedId ||
          !characteristic.properties.contains(CharacteristicProperty.notify)) {
        continue;
      }
      onCalibrationData?.call(
        await UniversalBle.read(deviceId, service.uuid, btChrCalibration),
      );
      await UniversalBle.subscribeNotifications(
        deviceId,
        service.uuid,
        characteristic.uuid,
      );
      // The link's transition to the usable [BtLinkState.streaming] state is
      // driven by the caller ([_onConnectionChange]) once this returns and the
      // generation guard confirms the pass wasn't superseded.
      return;
    }
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
    // MULTI-DEVICE (Path A): route by deviceId instead of dropping.
    if (deviceId != _link.deviceId || characteristicId != btChrAdcFeedId) {
      debugPrint(
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
    _setupGeneration++;

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
