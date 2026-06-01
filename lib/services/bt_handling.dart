import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import 'bt_device_config.dart';
import '../models/force_unit.dart';
// ignore: unused_import
import 'mockble.dart';

/// Lifecycle of a single device's BLE link.
///
/// This is intentionally a *per-device* concept even though, today, the app
/// only tracks one link at a time (see [DeviceLink] / [BluetoothHandling]).
///
/// MULTI-DEVICE (Path A): when we support N simultaneous devices, this enum
/// stays exactly as-is. The only change is that [BluetoothHandling] will hold a
/// `Map<String /*deviceId*/, DeviceLink>` instead of the single [_link] below,
/// and the UI will read each row's state from its own [DeviceLink]. The
/// adapter-availability and scanning state remain *global* (one radio), so they
/// do NOT move into [DeviceLink].
enum BtLinkState {
  /// No connection to this device; it may or may not be in the discovered list.
  idle,

  /// A `connect()` call is outstanding; not yet usable.
  connecting,

  /// Connected (and, once [DeviceLink.isSubscribed] is true, streaming).
  connected,

  /// A `disconnect()` was requested; awaiting the connection callback (or the
  /// disconnect() timeout). Connect must stay blocked while in this state so we
  /// never issue a connect against a half-torn-down link.
  disconnecting,
}

/// All per-device link state for a single BLE device.
///
/// MULTI-DEVICE (Path A): promote the single [BluetoothHandling._link] to a
/// `Map<String, DeviceLink>` keyed by [deviceId]. Each map entry owns its own
/// state/name/services/subscription. The migration is mechanical because
/// every field that is logically per-device already lives here rather than as a
/// loose field on [BluetoothHandling].
class DeviceLink {
  DeviceLink({this.deviceId = ''});

  /// Empty string means "no device" (the [BtLinkState.idle] sentinel).
  String deviceId;
  String name = '';
  BtLinkState state = BtLinkState.idle;
  bool isSubscribed = false;
  final List<BleService> services = [];

  /// Most recent live RSSI (dBm) for the connected device, polled while
  /// connected. Null until the first successful read (and after reset). This is
  /// the *connected* signal strength — distinct from the scan-time RSSI carried
  /// on each discovered [BleDevice].
  int? rssi;

  bool get isConnecting => state == BtLinkState.connecting;
  bool get isConnected => state == BtLinkState.connected;
  bool get isDisconnecting => state == BtLinkState.disconnecting;

  /// Reset back to the idle sentinel (used on disconnect).
  void reset() {
    deviceId = '';
    name = '';
    state = BtLinkState.idle;
    isSubscribed = false;
    rssi = null;
    services.clear();
  }
}

class BluetoothHandling extends ChangeNotifier {
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
  /// the device is not connected"). We wait out the remainder of this window
  /// before reconnecting to a recently-disconnected device.
  static const Duration reconnectSettleDelay = Duration(milliseconds: 600);

  /// Timestamp of the last observed disconnect, keyed by deviceId. Kept on the
  /// handler (not on [DeviceLink], which gets reset on disconnect) so the
  /// settle window survives the reset.
  ///
  /// MULTI-DEVICE (Path A): already per-device via this map.
  final Map<String, DateTime> _lastDisconnectAt = {};

  AvailabilityState _bluetoothState = AvailabilityState.unknown;
  AvailabilityState get bluetoothState => _bluetoothState;

  final List<BleDevice> _devices = [];
  List<BleDevice> get devices => _devices;

  /// Discovered services for the active link.
  List<BleService> get services => _link.services;

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

  /// True between a connect request and the connection result (success or
  /// failure). Used purely for UI status; never assume the device is usable
  /// while this is true.
  bool get isConnecting => _link.isConnecting;

  /// True while a disconnect has been requested but not yet confirmed.
  bool get isDisconnecting => _link.isDisconnecting;

  String get selectedDeviceId => _link.isConnected ? _link.deviceId : '';

  /// Name of the currently connected device.
  String get connectedDeviceName =>
      _link.name.isEmpty ? _link.deviceId : _link.name;

  bool get isSubscribed => _link.isSubscribed;

  /// Live RSSI (dBm) of the connected device, or null when not connected, not
  /// yet read, or unsupported on this platform. Polled every [rssiPollInterval]
  /// while connected.
  int? get connectedRssi => _link.isConnected ? _link.rssi : null;

  /// Whether the platform implements [UniversalBle.readRssi]. Web throws
  /// `notImplemented` for it; all native platforms (Android/Apple/Windows/Linux)
  /// support it. universal_ble has no dedicated capability flag for RSSI, so we
  /// gate on `!kIsWeb`.
  bool get _supportsRssi => !kIsWeb;

  /// Periodic poller for [connectedRssi]; runs only while a link is connected
  /// and the platform supports RSSI reads.
  Timer? _rssiPollTimer;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  /// Called when a disconnect gives up after [disconnectTimeout] without the
  /// link returning to idle. The argument is the affected device's display name
  /// (or id). The UI uses this to surface a brief notice.
  ///
  /// MULTI-DEVICE (Path A): already carries the device identity, so the message
  /// can name the specific device that failed to disconnect.
  void Function(String deviceName)? onDisconnectTimeout;

  /// Called when a connection drops or fails during post-connect setup (e.g.
  /// the device disappears mid service-discovery). The argument is the device's
  /// display name (or id). The UI uses this to surface a brief notice.
  void Function(String deviceName)? onConnectionFailed;

  final DataHub dataHub = DataHub();

  BluetoothHandling() {
    if (useMockBt) {
      UniversalBle.setInstance(MockBlePlatform.instance);
    }
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onConnectionParametersChange = _onConnectionParametersChange;
    UniversalBle.onValueChange = _processReceivedData;

    unawaited(_updateBluetoothState());
  }

  void stopProcessing() {
    UniversalBle.onValueChange = null;
    _stopRssiPolling();
    dataHub._prevSampleCount = -1;
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth();
    }
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    notifyListeners();
  }

  void _onScanResult(BleDevice newDevice) {
    // Keep all discovered devices (replace if same ID seen again with better RSSI).
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
      if (newDevice.rssi != null &&
          (_devices[existingIdx].rssi == null ||
              newDevice.rssi! > _devices[existingIdx].rssi!)) {
        _devices[existingIdx] = newDevice;
      }
    } else {
      _devices.add(newDevice);
    }
    notifyListeners();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
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
    // (connecting/disconnecting) rather than a single subscribed flag.
    if (_link.isSubscribed) {
      return;
    }
    await disconnectSelectedDevice();
    _devices.clear();
    _link.services.clear();
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

  void toggleSession() {
    assert(_link.isConnected);
    if (!_sessionInProgress) {
      // Starting a recording: mark the current logical time.
      dataHub._recordingStartIdx = dataHub.totalSamples;
    }
    _sessionInProgress = !_sessionInProgress;
    dataHub._prevSampleCount = -1;
    notifyListeners();
  }

  void stopSession() {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      dataHub._prevSampleCount = -1;
      notifyListeners();
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
      // Stop polling if the link is no longer this connected device.
      if (!_link.isConnected || _link.deviceId != deviceId) {
        _stopRssiPolling();
        return;
      }
      try {
        final int rssi = await UniversalBle.readRssi(deviceId);
        // Guard again: the link may have changed during the await.
        if (_link.isConnected && _link.deviceId == deviceId) {
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
      _link.deviceId = deviceId;
      _link.state = BtLinkState.connected;

      // Store the device name
      final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
      _link.name = device?.name ?? deviceId;

      // Reflect "Connected" in the UI immediately, BEFORE the awaited setup
      // work below. Otherwise the label stays on "Connecting…" until discovery
      // finishes (and never updates at all if discovery throws).
      notifyListeners();

      // Post-connect setup. If the device drops mid-setup (common when Chrome
      // accepts a too-soon reconnect then tears it down ~2.5s later), these
      // calls throw "Cannot discover services…". Catch it, treat it as a failed
      // connection, and reset to idle instead of leaving an uncaught exception
      // and a half-connected limbo.
      try {
        if (!kIsWeb) {
          debugPrint('Requested MTU change');
          final int mtu = await UniversalBle.requestMtu(deviceId, 247);
          debugPrint('MTU set to: $mtu');
          // TODO(perf): investigate requesting high-performance connection
          // priority here for the 1 kHz ADC stream:
          //   await UniversalBle.requestConnectionPriority(
          //     deviceId, BleConnectionPriority.highPerformance);
          // Android-only (BleCapabilities.supportsConnectionPriorityApi); throws
          // notSupported elsewhere. Should run after MTU negotiation. Measure
          // whether the tighter connection interval actually reduces dropped
          // samples before enabling.
        }
        _link.services.addAll(await UniversalBle.discoverServices(deviceId));
        for (final srv in _link.services) {
          if (srv.uuid == btServiceId) {
            await subscribeToAdcFeed(srv);
            break;
          }
        }
        // Connected and set up: begin live RSSI polling for the signal display.
        if (_link.deviceId == deviceId && _link.isConnected) {
          _startRssiPolling(deviceId);
        }
      } catch (e) {
        debugPrint('Post-connect setup failed for $deviceId: $e');
        final String name = _link.name.isEmpty ? deviceId : _link.name;
        // Only reset if this is still the link we were setting up (a real
        // disconnect callback may have already reset/replaced it).
        if (_link.deviceId == deviceId) {
          _stopRssiPolling();
          _lastDisconnectAt[deviceId] = DateTime.now();
          _link.reset();
          _sessionInProgress = false;
        }
        onConnectionFailed?.call(name);
        notifyListeners();
      }
    } else {
      // Disconnect resolved (whether user-requested or unexpected): record the
      // time (for the reconnect settle window) and reset the link to the idle
      // sentinel.
      _stopRssiPolling();
      _lastDisconnectAt[deviceId] = DateTime.now();
      _link.reset();
      _sessionInProgress = false;
      notifyListeners();
    }
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await _stopScan();
    }
    // Block connecting while a link is busy (connecting/connected/disconnecting).
    // The disconnecting case is what stops the "double-click after Disconnect"
    // race: the device row's Connect button is disabled until the link returns
    // to idle (via the disconnect callback or the disconnect() timeout
    // reconciliation), so we never reach here.
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
    _link.deviceId = deviceId;
    _link.state = BtLinkState.connecting;
    notifyListeners();

    // Fix 1: if this device was disconnected very recently, wait out the
    // remainder of the settle window so the stack (Chrome especially) finishes
    // GATT teardown before we ask it to reconnect. We're already showing
    // "Connecting…", which is honest — we are about to connect.
    final lastDisconnect = _lastDisconnectAt[deviceId];
    if (lastDisconnect != null) {
      final elapsed = DateTime.now().difference(lastDisconnect);
      final remaining = reconnectSettleDelay - elapsed;
      if (remaining > Duration.zero) {
        debugPrint('Waiting ${remaining.inMilliseconds}ms for $deviceId to settle');
        await Future<void>.delayed(remaining);
      }
    }

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
    if (!_link.isConnected) {
      return;
    }
    final String deviceId = _link.deviceId;
    final String deviceName = _link.name.isEmpty ? deviceId : _link.name;
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

    if (_link.deviceId == deviceId && _link.state == BtLinkState.disconnecting) {
      debugPrint('Disconnect did not settle for $deviceId; forcing idle');
      _stopRssiPolling();
      _lastDisconnectAt[deviceId] = DateTime.now();
      _link.reset();
      _sessionInProgress = false;
      onDisconnectTimeout?.call(deviceName);
      notifyListeners();
    }
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    final String deviceId = _link.deviceId;
    if (deviceId.isEmpty) {
      return;
    }
    for (final characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        dataHub._updateCalibration(
          await UniversalBle.read(
            deviceId,
            service.uuid,
            btChrCalibration,
          ),
        );
        await UniversalBle.subscribeNotifications(
          deviceId,
          service.uuid,
          characteristic.uuid,
        );
        _link.isSubscribed = true;
        notifyListeners();
        return;
      }
    }
  }

  void _processReceivedData(String _, String _, Uint8List data, int? _) {
    // Always stream data to the DataHub for live display.
    final canContinue = dataHub._parseDataPacket(data);
    if (!canContinue) {
      stopSession();
    }
  }
}

class DataHub extends ChangeNotifier {
  /// Number of ADC channels the device streams. This is also the number of
  /// lines stored and displayed: channel index == storage index == display index.
  static const int numAdcChannels = nwNumAdcChan;
  static const int _tareWindow = 1024;
  static const int samplesPerSec = 1000;
  static const int maxDataSz = samplesPerSec * 60 * 10;
  final Float64List tare = Float64List(numAdcChannels);
  final Float64List _runningTotal = Float64List(numAdcChannels);
  final Int32List rawMax = Int32List(numAdcChannels);
  final Int32List rawMin = Int32List(numAdcChannels);

  /// Latest raw value per channel (for live stats display).
  final Int32List _currentRaw = Int32List(numAdcChannels);

  final List<Int32List> rawData = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(maxDataSz),
    growable: false,
  );
  int _tareCount = _tareWindow;
  int totalSamples = 0;
  int _prevSampleCount = -1;
  DeviceCalibration deviceCalibration = DeviceCalibration();

  /// Index into logical time where the current recording started.
  /// Used by SessionStorage to know which slice to save.
  int _recordingStartIdx = 0;
  int get recordingStartIdx => _recordingStartIdx;

  void clear() {
    _tareCount = _tareWindow;
    totalSamples = 0;
    _recordingStartIdx = 0;
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = 0;
      rawMin[i] = 0;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
    }
  }

  bool get taring => (_tareCount > 0);

  /// Request a new tare operation (zeros readings using next N samples).
  void requestTare() {
    _tareCount = _tareWindow;
    for (int i = 0; i < numAdcChannels; ++i) {
      tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  /// Get current force for a given ADC channel in the specified unit.
  double currentForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = _currentRaw[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get peak force for a given ADC channel in the specified unit.
  double peakForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMax[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get minimum (most negative) force for a given ADC channel in the specified unit.
  double minForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMin[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get the instantaneous derivative (first-difference) for a channel in unit/s.
  double currentDerivative(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples < 2) {
      return 0;
    }

    final diff = rawData[adcChannel][(totalSamples - 1) % maxDataSz] - rawData[adcChannel][(totalSamples - 2) % maxDataSz];
    // Derivative is raw diff per sample * samplesPerSec to get raw per sec
    return unit.fromRaw(diff.toDouble() * samplesPerSec, deviceCalibration.slope);
  }

  /// Get the AC RMS for a given ADC channel in the specified unit over the last 1 second window.
  double acRmsForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples == 0) {
      return 0;
    }

    final int count = math.min(samplesPerSec, totalSamples);
    final lineData = rawData[adcChannel];
    final startIdx = totalSamples - count;

    double sum = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      sum += lineData[i % maxDataSz];
    }
    final mean = sum / count;

    double sumSq = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      final diff = lineData[i % maxDataSz] - mean;
      sumSq += diff * diff;
    }
    final rmsRaw = math.sqrt(sumSq / count);

    return unit.fromRaw(rmsRaw, deviceCalibration.slope);
  }

  void injectTestData(int samples) {
    int added = 0;
    for (int i = 0; i < samples; i++) {
      final double phase = totalSamples * 2 * math.pi / samplesPerSec * 0.5;

      // Generate dummy waveforms for all channels so every line is exercised.
      // ch0: sine, ch1: cosine, ch2: half-amplitude sine, ch3: phase-shifted sine
      final values = <int>[
        (math.sin(phase) * 50000 + 50000).toInt(),
        (math.cos(phase) * 30000 + 30000).toInt(),
        (math.sin(phase) * 25000 + 25000).toInt(),
        (math.sin(phase + math.pi / 4) * 40000 + 40000).toInt(),
      ];

      for (int ch = 0; ch < numAdcChannels; ch++) {
        final val = values[ch];
        rawData[ch][totalSamples % maxDataSz] = val;
        _currentRaw[ch] = val;
        _addData(val, ch);
      }

      totalSamples++;
      added++;
    }

    if (added > 0) {
      notifyListeners();
    }
  }

  void _addTare(int val, int idx) {
    _runningTotal[idx] += val;
  }

  void _addData(int val, int idx) {
    rawData[idx][totalSamples % maxDataSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
    if (val < rawMin[idx]) {
      rawMin[idx] = val;
    }
  }

  void _updateCalibration(Uint8List data) {
    // TODO: implement calibration parsing
    deviceCalibration = DeviceCalibration();
    debugPrint(
      'Calibration ${deviceCalibration.slope}, offset ${deviceCalibration.offset}',
    );
  }

  /// Parse a BLE data packet.
  /// Data is always buffered for live display. Recording start/end is
  /// tracked via [_recordingStartIdx] set by BluetoothHandling.toggleSession().
  bool _parseDataPacket(Uint8List data) {
    if (data.isEmpty) {
      debugPrint("data isEmpty");
      return false;
    }

    final int count = data[0] + (data[1] << 8);
    if (_prevSampleCount != -1) {
      final int diff = (count - _prevSampleCount) & 0xFFFF;
      if (diff != 0) {
        debugPrint('# lost $diff samples');
        // TODO: signal lost packets
      }
    }
    _prevSampleCount = (count + nwAdcNumSamples) & 0xFFFF;

    for (
      int packetStart = nwHeaderSize;
      packetStart < nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength;
      packetStart += nwAdcSampleLength
    ) {
      assert(packetStart + nwAdcSampleLength <= data.length);
      for (int i = 0; i < nwNumAdcChan; ++i) {
        final int baseIndex = packetStart + i * 3;
        final int res =
            ((data[baseIndex] << 0) |
                    (data[baseIndex + 1] << 8) |
                    data[baseIndex + 2] << 16)
                .toSigned(24);

        // Channel index == storage line index.
        if (i < numAdcChannels) {
          _currentRaw[i] = res;
          if (taring) {
            _addTare(res, i);
          } else {
            // Always buffer data for live display.
            _addData(res, i);
          }
        }
      }

      if (taring) {
        _tareCount--;
        if (!taring) {
          for (int i = 0; i < _runningTotal.length; ++i) {
            tare[i] = _runningTotal[i] / _tareWindow;
            _runningTotal[i] = 0;
          }
        }
      } else {
        totalSamples++;
      }
    }

    notifyListeners();
    return true; // We never run out of space now
  }
}

class DeviceCalibration {
  DeviceCalibration({
    this.offset = 0,
    this.capacityKg = 200.0,
    this.sensitivityMvV = 2.0,
    this.excitationV = 4.5,
  });

  final int offset;
  final double capacityKg;
  final double sensitivityMvV;
  final double excitationV;

  /// Calculates kgf per raw count dynamically based on the parameters
  double get slope {
    final maxMv = sensitivityMvV * excitationV;
    return (capacityKg * ForceUnit.rawToMvMultiplier) / maxMv;
  }
}
