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

/// Why a connect attempt failed, for the Devices tab's per-row failure marker
/// (see [BleLinkManager.connectFailureFor]). The manager records only the
/// kind; the row maps it to user-facing copy (copy stays in the UI layer).
enum ConnectFailureKind {
  /// The platform refused/failed the connection outright. On web this is
  /// typically Chrome rejecting gatt.connect() on a stale device handle (a
  /// row left over from an earlier session — universal_ble wraps the
  /// NetworkError as UniversalBleErrorCode.unknownError); the actual fix is
  /// a fresh Scan + pick, which mints a new handle.
  failed,

  /// The attempt exceeded [BleLinkManager.connectTimeout]. The platform
  /// attempt may still complete late; the unwanted-link guard releases it.
  timeout,
}

/// Live feed telemetry for one link: the smallest/largest ADC notification
/// sizes seen (bytes, malformed packets included) and the most recent RSSI.
/// Holds nullable fields on purpose — each is unknown until its first
/// reading — but lives inside [LinkInfo], so it exists only while the link
/// does and can never mean "no device".
class LinkTelemetry {
  int? rssi;
  int? minAdcPacketBytes;
  int? maxAdcPacketBytes;
}

/// The immutable connect-time facts of a usable (streaming) link: identity,
/// the readback pieces post-connect setup collected, and the backend. The
/// stored name is the one mutable fact (a device-name write updates it); live
/// telemetry hangs off [telemetry].
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

/// The link state: exactly one of "no link", "a link is coming up", "a link
/// is up and being set up", "a link is ready (streaming)", or "tearing down".
/// This is the single source of "is there a device": no empty-string sentinel,
/// no nullable backend, no separate idle flag to keep in sync.
sealed class Link {
  const Link();

  String get deviceId;
  LinkTransport? get transport;
  LinkTelemetry? get telemetry => null;
  String? get storedName => null;
  DeviceInfo? get deviceInfo => null;
  int? get mtu => null;
  AdcConfig? get adcConfig => null;

  /// The device-side backend, or null before it is brought up.
  LinkBackend? get backend => transport?.backend;

  /// The GATT link is up. True for the whole post-connect setup window and
  /// the usable ([streaming]) state — use [isStreaming] for "usable".
  bool get isLinkUp;

  /// The link's terminal "ready" state: link up AND the ADC feed subscribed.
  /// NOT proof of data flow — notifications can still be absent or
  /// undecodable; the measured-traffic truth is deriveFeedHealth's.
  bool get isStreaming;

  /// The lifecycle stage, for status readouts (see [BtLinkState]).
  BtLinkState get state;

  /// The display name: the stored name when set, else the advertised name (or
  /// the device id when that's empty too). Empty when there is no link.
  String get displayName {
    final t = transport;
    if (t == null) return '';
    return storedName ?? (t.displayName.isEmpty ? t.deviceId : t.displayName);
  }
}

/// The idle sentinel: no device at all.
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

/// A `connect()` call is outstanding; the GATT link is not up yet.
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

/// The GATT link is up and post-connect setup is running. The fields fill in
/// as setup progresses, so they are mutable and nullable here — but this
/// record exists only during the setup window, never as a resting state.
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

/// A fully set-up, usable link.
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

/// A disconnect was requested; the link is waiting for the platform callback
/// (or the disconnect timeout).
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

/// True for the web picker outcomes that are user choices, not failures: the
/// user dismissed the requestDevice() chooser, it reported no matching
/// devices, or the browser aborted the pick for its own reason. On web the
/// picker IS the scan, so closing it without a selection means "the user
/// changed their mind" — there is no radio failure to report. Chrome signals
/// dismissal with UserCancelledDialogError / DeviceNotFoundError; Bluefy with
/// a BrowserError carrying its own cancel code. flutter_web_bluetooth
/// rethrows these verbatim but does NOT re-export the classes, so they can't
/// be caught by type here without a direct dependency on the web-only
/// package; match the class's own toString prefix ("$errorName: …") instead.
/// A BrowserError wrapping a SecurityError (permissions-policy denial, not a
/// cancel) stays on the genuine-failure path. Trade-off: a rare genuine
/// browser error (e.g. Bluefy refusing the pick for another reason) is
/// swallowed as a dismissal — the user just sees nothing happen and taps
/// Scan again, preferable to toasting an inscrutable error for the everyday
/// cancel.
bool isWebPickerDismissal(Object e) {
  final s = e.toString();
  return s.startsWith('UserCancelledDialogError') ||
      s.startsWith('DeviceNotFoundError') ||
      (s.startsWith('BrowserError') && !s.contains('SecurityError'));
}

/// The BLE link state machine: adapter availability, scanning, connect /
/// post-connect setup / disconnect, the web reconnect-settle embargo
/// ([reconnectSettleDelay]), and live RSSI polling.
///
/// This class owns *only* the link. It knows nothing about the recording:
/// raw notification bytes and the parsed flash document are handed off via
/// [onAdcData] / [onDeviceFlash] (constructor-injected at app startup), and
/// recording observes this notifier's state changes (see
/// [RecordingController]).
///
/// MULTI-DEVICE ROADMAP: today exactly one link is tracked ([_link]), and
/// [QueueType.perDevice] already isolates per-device command queues. To
/// support N simultaneous devices, promote [_link] to a
/// `Map<String /*deviceId*/, Link>`: every logically per-device fact lives on
/// the [Link] (_bt_scan.dart's [BtLinkState], [LinkInfo], telemetry), so the
/// migration is mechanical — per-device lookup in [_onConnectionChange] and
/// [_onValueChange] (route by deviceId instead of dropping), per-device busy
/// guards in [_beginLink] and [disconnectSelectedDevice]. Adapter
/// availability and scanning stay *global* (one radio) and do NOT move into
/// [Link].
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
  /// defaults to 60 s. When it fires, the
  /// platform connect may still complete later — that late callback is
  /// released and ignored by the unwanted-link guard in [_onConnectionChange].
  static const Duration connectTimeout = Duration(seconds: 5);

  /// How often to poll the connected device's RSSI for the live signal display.
  static const Duration rssiPollInterval = Duration(seconds: 2);

  /// How long a device row's "last proof of life" (see [lastAliveMs]) may
  /// age before the Devices tab de-emphasizes the row as stale. Single knob
  /// for the freshness window.
  static const Duration deviceStaleAfter = Duration(seconds: 10);

  /// After a device disconnects, some BLE stacks (notably Web Bluetooth on
  /// Chrome) need a moment to finish tearing down GATT before they will accept
  /// a fresh connection to the SAME device. Reconnecting sooner makes Chrome
  /// briefly accept then drop the link (and throws "Cannot discover services if
  /// the device is not connected"). Web Bluetooth exposes no teardown-complete
  /// event, so the safety margin is a wall-clock guess — which is exactly
  /// what a timestamp models: see [_reconnectNotBefore]. Native stacks don't
  /// exhibit the race and stamp nothing.
  static const Duration reconnectSettleDelay = Duration(milliseconds: 4000);

  /// Per-device "do not reconnect before" embargo (ms-precision wall clock),
  /// stamped at teardown of a LIVE web link (see [_teardownLink]; web only —
  /// a failed connect attempt never had a live link to settle and stamps
  /// nothing). At most one unexpired stamp can exist: a new link can't come
  /// up while [linkBusy] reports one pending, so each teardown's stamp is
  /// sealed before the next one can be written. This is the ONLY fact kept
  /// about the window: [linkBusy] and [reconnectPendingFor] both recompute
  /// from it when consulted, so nothing needs maintaining (no early-finish
  /// cleanup on scan kick-off — a cancelled picker leaves the embargo
  /// standing, which is what blocks the machine-speed manual-reconnect race
  /// on a device the user never re-picked). A successful picker pass clears
  /// it: tested on Chrome, a device mid-teardown doesn't appear in
  /// requestDevice() at all, so a pick IS the teardown-settle signal this
  /// stamp otherwise guesses at (see [_connectPickedWebDevice]).
  final Map<String, DateTime> _reconnectNotBefore = {};

  /// Whether [deviceId] is inside its web reconnect-settle window. The
  /// Devices tab shows the row's "Waiting after disconnect…" hint (and keeps
  /// Connect disabled via [linkBusy]) while this is true.
  bool reconnectPendingFor(String deviceId) {
    final notBefore = _reconnectNotBefore[deviceId];
    return notBefore != null && notBefore.isAfter(DateTime.now());
  }

  /// Zero-state poke so Connect buttons re-enable promptly at window end
  /// even when nothing else happens meanwhile. It DECIDES nothing (it never
  /// mutates the stamp — getters recompute from [_reconnectNotBefore]), so a
  /// late, early, or superseded fire is harmless; a fresh teardown replaces
  /// it with its own deadline.
  Timer? _reconnectPoke;

  /// Epoch counter for the async post-connect setup cancellation tokens (see
  /// [_SetupToken]). Bumped on every connect request, disconnect request, and
  /// teardown via [_supersedeSetupPasses]; async setup code captures a token
  /// and re-checks it after each `await`, bailing out silently when
  /// superseded, so rapid connect/disconnect clicks can't corrupt link state
  /// or spam toasts.
  int _setupEpoch = 0;

  /// Issue a cancellation token for a new setup pass over the current epoch.
  _SetupToken _setupTokenFor(String deviceId) =>
      _SetupToken(this, _setupEpoch, deviceId);

  /// Supersede every outstanding setup pass (a newer connect, a disconnect,
  /// or a teardown happened).
  void _supersedeSetupPasses() => _setupEpoch++;

  /// The adapter state, exposed as the app-level [BtAvailability]: the
  /// plugin's `AvailabilityState` never leaves this class (converted on
  /// ingress — see [_updateBluetoothState]).
  BtAvailability _bluetoothState = BtAvailability.unknown;
  BtAvailability get bluetoothState => _bluetoothState;

  /// Scanned devices as app-level [DiscoveredDevice]s: universal_ble's
  /// `BleDevice` is mapped at the scan-result boundary (see [_onScanResult])
  /// and never escapes.
  final List<DiscoveredDevice> _devices = [];
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// The single active device link (see the multi-device roadmap on the
  /// class). The getters below project it into the flat API the UI consumes
  /// today.
  Link _link = const NoLink();

  /// Per-device record of the most recent failed connect attempt, keyed by
  /// device id. Set in [_beginLink]'s catch (only for the attempt that
  /// actually surfaces the failure — an abandoned/cancelled attempt records
  /// nothing), cleared when any new connect attempt begins (see
  /// [_beginConnect]) or when a fresh scan result arrives for that device (a
  /// re-discovered device is a fresh platform handle — see [_onScanResult]).
  /// The Devices tab shows a per-row failure hint from this instead of a
  /// toast, so rapid retries can't queue a stack of snackbars.
  final Map<String, ConnectFailureKind> _connectFailures = {};

  /// The kind of the last failed connect attempt for [deviceId], or null if
  /// none (or it was superseded/cleared).
  ConnectFailureKind? connectFailureFor(String deviceId) =>
      _connectFailures[deviceId];

  /// Per-device record of the platform's error string from the most recent
  /// UNEXPECTED link drop, keyed by device id. Set in [_onConnectionChange]
  /// only when the platform actually provides one (many stacks give none);
  /// a reasonless drop clears any stale entry for that device so it can't be
  /// misattributed to the new drop. Cleared wholesale when any new connect
  /// attempt begins (see [_beginConnect]) — but NOT on re-discovery: unlike
  /// a connect FAILURE marker (whose remedy is "rescan and retry", moot once
  /// re-found), this string describes the drop event itself, which stays
  /// true however the device is re-discovered. A user-requested disconnect
  /// is not an error and records nothing. The Devices tab shows this as the
  /// inactive row's hint when there is no connect-failure marker.
  final Map<String, String> _lastDisconnectErrors = {};

  /// The platform's error string from [deviceId]'s last unexpected drop, or
  /// null when the platform provided none (or the device never dropped).
  String? lastDisconnectErrorFor(String deviceId) =>
      _lastDisconnectErrors[deviceId];

  /// Per-device detail of the most recent post-connect setup failure, keyed
  /// by device id: a transport/protocol failure (the link is torn down). Set
  /// in [_runPostConnectSetup]'s catch; cleared wholesale when any new connect
  /// attempt begins (see [_beginConnect]). The Devices tab shows it as the
  /// row hint, where it persists (unlike the toast) so it can be read or
  /// screenshotted.
  final Map<String, String> _setupFailures = {};

  /// The setup failure detail for [deviceId], or null if none (or it was
  /// cleared by a new attempt).
  String? setupFailureFor(String deviceId) => _setupFailures[deviceId];

  /// Last "proof of life" per device id (ms since epoch): the most recent
  /// moment a GATT link to this device was provably up (see [_stampAlive]).
  /// Never stamped for failed/cancelled connects (a refused attempt proves
  /// nothing about the device being alive) or for simulated links.
  final Map<String, int> _lastAliveMs = {};

  /// The most recent moment (ms since epoch) this device was provably alive,
  /// or null if never. Native folds in the latest advertisement receipt
  /// ([DiscoveredDevice.timestamp], refreshed per advert while scanning) so the
  /// value covers both "seen" and "connected" evidence; web uses connection
  /// stamps only — the picker pick-time is not a connection and must not
  /// count as a sighting on its own. The Devices tab renders this as "Last
  /// seen" on both platforms (web: connection stamps only — no adverts
  /// exist) and stales it out after [deviceStaleAfter].
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

  /// Record a proof of life for [deviceId]: a GATT link was provably up.
  /// Callers: the link reaching streaming, a user-requested disconnect of a
  /// live link (see [disconnectSelectedDevice] — the callback can't, see
  /// there), the disconnect callback for an unexpectedly dropped link, and
  /// the post-connect setup-failure path (GATT came up but
  /// discovery/subscription failed). All four are moments where the device
  /// demonstrably answered.
  void _stampAlive(String deviceId) {
    if (deviceId.isEmpty) return;
    // Simulated links have no radio lifetime to attest.
    if (_link.transport?.isSimulated ?? false) return;
    _lastAliveMs[deviceId] = DateTime.now().millisecondsSinceEpoch;
  }

  /// The single "usable / connected" truth: link up AND the ADC feed is
  /// streaming. Every screen keys its connected UI off this.
  bool get isStreaming => _link.isStreaming;

  /// Whether a GATT link is up (during setup or streaming). The "device
  /// present" port consumers use to react to link transitions.
  bool get isLinkUp => _link.isLinkUp;

  /// Whether the active link is the simulated demo device (false when idle).
  bool get isSimulated => _link.transport?.isSimulated ?? false;

  /// Lifecycle state of the active link ([BtLinkState.idle] when no link):
  /// the full progression for status readouts that must distinguish "no
  /// link" from "a link transition is in flight" (the Live tab's banner
  /// and connect prompt). For "usable", use [isStreaming].
  BtLinkState get linkState => _link.state;

  /// A link is "busy" whenever it is mid-transition or active; device-row
  /// Connect buttons stay disabled until it returns to idle. This is what
  /// prevents the disconnect→reconnect double-click race. On web the busy
  /// window OUTLIVES the link: a just-torn-down device keeps its
  /// [_reconnectNotBefore] embargo until [reconnectSettleDelay] has elapsed,
  /// because the stack isn't yet ready to accept a fresh connection to it.
  /// Recomputed on every call from the stored facts (link state + stamp), so
  /// it can't drift from either.
  bool get linkBusy =>
      _link.state != BtLinkState.idle ||
      _reconnectNotBefore.values.any((t) => t.isAfter(DateTime.now()));

  /// Device id of the active link whenever the GATT link is up (during setup or
  /// while streaming); empty otherwise.
  String get connectedDeviceId => _link.isLinkUp ? _link.deviceId : '';

  /// Device id of the active link for the whole link lifecycle — including
  /// `connecting` and `disconnecting`; empty only when idle. The Devices tab
  /// uses it to find the active row while its state is still transitioning.
  String get activeDeviceId => _link.deviceId;

  /// Name of the currently connected device: the Settings-stored name when
  /// the device has one, else the advertised name (or the device id when
  /// that's empty). Empty with no link.
  String get connectedDeviceName => _link.displayName;

  /// The Settings-stored name of the connected device, or null when unset
  /// on the device, not yet read, or no link up. [connectedDeviceName]
  /// overlays this; write via [setDeviceName].
  String? get connectedStoredDeviceName =>
      _link.isLinkUp ? _link.storedName : null;

  /// Static identity (Device Information service) of the connected device,
  /// read once during post-connect setup; null with no link up or until the
  /// read completes. Per-field nulls cover individual read failures (and web,
  /// where the serial number characteristic is blocklisted).
  DeviceInfo? get connectedDeviceInfo =>
      _link.isLinkUp ? _link.deviceInfo : null;

  /// ATT MTU negotiated at connect, or null with no link up, until the
  /// request completes, or on platforms/paths that never negotiate (web,
  /// demo).
  int? get negotiatedMtu => _link.isLinkUp ? _link.mtu : null;

  /// Smallest ADC-feed notification (bytes) on the current link, or null
  /// until a packet arrives / once the link is down.
  int? get minAdcPacketBytes =>
      _link.isLinkUp ? _link.telemetry?.minAdcPacketBytes : null;

  /// Largest ADC-feed notification (bytes) on the current link, or null
  /// until a packet arrives / once the link is down.
  int? get maxAdcPacketBytes =>
      _link.isLinkUp ? _link.telemetry?.maxAdcPacketBytes : null;

  /// Live RSSI (dBm) of the connected device, or null when not streaming, not
  /// yet read, or unsupported on this platform. Polled every [rssiPollInterval]
  /// while streaming.
  int? get connectedRssi => _link.isStreaming ? _link.telemetry?.rssi : null;

  /// The device-side backend of the active link (slot writes and the
  /// save-verification read), or null when no link is up.
  LinkBackend? get backend => _link.backend;

  /// Whether the platform implements [UniversalBle.readRssi]. Web throws
  /// `notImplemented` for it; all native platforms (Android/Apple/Windows/Linux)
  /// support it. universal_ble has no dedicated capability flag for RSSI, so we
  /// gate on `!kIsWeb`.
  bool get _supportsRssi => !kIsWeb;

  /// Whether scan results on this platform can carry an advertisement RSSI.
  /// On web they never do: the "scan" is Chrome's requestDevice() picker, which
  /// has no RSSI, and the only other path (watchAdvertisements) is flag-gated
  /// and abandoned by Chrome. Distinct from [_supportsRssi], which gates
  /// connected-mode readRssi polling; the Devices tab uses this to drop the
  /// RSSI slot entirely where no reading can ever exist.
  bool get supportsScanRssi => !kIsWeb;

  /// Periodic poller for [connectedRssi]; runs for the link's whole
  /// streaming lifetime (see [_startRssiPolling]).
  Timer? _rssiPollTimer;

  /// Whether the Devices tab is currently visible. Gates the on-screen-only
  /// device-row freshness poke (see [_syncFreshnessPoke]).
  bool _devicesTabVisible = false;

  /// Called by the shell when the Devices tab becomes visible/hidden.
  void setDevicesTabVisible(bool visible) {
    if (_devicesTabVisible == visible) return;
    _devicesTabVisible = visible;
    _syncFreshnessPoke();
  }

  /// 1 Hz "time passed" poke while the Devices tab is visible and rows exist,
  /// so the rows' relative ages ("Last seen >15 seconds ago") and the
  /// [deviceStaleAfter] stale flip re-render on time. Changes no state itself
  /// — like the RSSI poller it only notifies; other tabs guard their rebuilds
  /// with narrow selects.
  Timer? _freshnessPoke;

  /// Start/stop the freshness poke to match [_devicesTabVisible] and whether
  /// there are any device rows to age. Called from [setDevicesTabVisible],
  /// [_onScanResult] (rows appear), and [_onBluetoothAvailabilityChanged]
  /// (rows cleared).
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

  /// Raw ADC-feed notification bytes, exactly as received. Constructor-injected
  /// by the composition root (wired to the protocol layer's
  /// `AdcPacketDecoder.onDataPacket`); the link manager itself never
  /// interprets them. Reassigned to a no-op on hot restart so the stale
  /// generation's feed stops synchronously (see [shutdownForHotRestart]).
  void Function(Uint8List data) _onAdcData;

  /// The parsed connect-time flash document (board calibration, load cell
  /// slots, raw KVS provenance), delivered once during post-connect setup.
  /// Injected at app startup; the flash never reaches the app unparsed — see
  /// [_runPostConnectSetup].
  final void Function(DeviceFlash flash) onDeviceFlash;

  /// The stream's sample rate (Hz), delivered once per link before the feed
  /// starts (parsed from the ADC config readback on GATT links; the demo
  /// device declares its own). Wired to [DataHub.setSampleRate] at app
  /// startup — everything below the protocol layer reads the rate from the
  /// hub. Reassigned to a no-op on hot restart.
  void Function(int sampleRateHz) _onSampleRate;

  /// True while the active link is the simulated demo device, which has no
  /// OTA service. The update UI gates flash actions off this.
  bool get linkIsSimulated => isSimulated && isLinkUp;

  /// One-shot user notices ([BleDisconnectTimeout], [BleConnectionFailed])
  /// go here; the shell shows them regardless of which tab is mounted.
  final AppEvents _events;

  /// The simulated link, wired by the composition root. Null only in tests
  /// that construct a bare manager; every simulated connect path is then
  /// unreachable (no demo connect can begin without [_demo]).
  final LinkTransport? _demo;

  /// The feed-maintenance chain. [KvsClient] serializes individual KVS
  /// commands, but nothing stops one envelope's resubscribe from landing
  /// inside the NEXT envelope's command body — locking the device against
  /// its remaining commands. Envelopes are appended here so each runs to
  /// completion before the next starts; the chain always settles, so a
  /// failed envelope never wedges the ones queued behind it (an op queued
  /// behind a torn-down link fails loudly on the aborted KVS client).
  Future<void> _feedMaintenance = Future.value();

  /// Run [body] as an OTA flash session against the live link. The GATT
  /// plumbing (control subscription, wired [OtaClient], feed pause, teardown)
  /// lives on the transport ([LinkTransport.runOta]); this forwards so callers
  /// stay link-shaped. Idle — no link — throws here; a transport without OTA
  /// (the demo) throws there.
  ///
  /// A body that RETURNS had its image accepted — the device reboots into it
  /// ~0.5 s later (see [OtaClient.flash]) — so the link is then ended via the
  /// requested-disconnect path; the feed-pause envelope's resume, its default
  /// epilogue, could only time out against the dying radio. A body that THROWS
  /// keeps the link (nothing rebooted): the envelope resumes the feed and the
  /// error reaches the caller.
  Future<T> runOta<T>(Future<T> Function(OtaClient client) body) async {
    final transport = _link.transport;
    if (transport == null) {
      throw StateError('OTA requires a connected device');
    }
    return transport.runOta((client) async {
      final result = await body(client);
      // The reboot may already have dropped the link on its own; end the
      // session only while the live link is still the one that flashed.
      if (identical(_link.transport, transport)) {
        await disconnectSelectedDevice();
      }
      return result;
    });
  }

  /// Run [body] with the ADC feed subscription paused: firmware rejects KVS
  /// commands while the feed's subscription holds the device lock, so doc
  /// writes (and the verifying re-read) briefly unsubscribe, then
  /// resubscribe. The feed's counter jump on resume surfaces as a gap via
  /// the decoder's continuity check. When the feed isn't active
  /// (mid setup) [body] just runs. Handed to the GATT transport, the only
  /// caller.
  Future<T> _withFeedPaused<T>(Future<T> Function() body) {
    final op = _feedMaintenance.then((_) => _feedPausedEnvelope(body));
    _feedMaintenance = op.then<void>((_) {}, onError: (_) {});
    return op;
  }

  /// Settle grace between pausing the feed and the envelope's first KVS
  /// command. The firmware releases its device lock inside the CCC-write
  /// callback, ahead of the unsubscribe's completion — but only when the
  /// platform actually ordered and awaited the descriptor write. A KVS
  /// write that lands while the lock still holds is dropped silently and
  /// costs a full command timeout; the grace is the cheap fix.
  static const Duration _feedPauseSettle = Duration(milliseconds: 300);

  /// One feed-maintenance envelope: unsubscribe the ADC feed, run [body],
  /// resubscribe. Runs exclusively inside the [_feedMaintenance] chain, so
  /// subscribe/unsubscribe pairs of concurrent ops can never interleave.
  Future<T> _feedPausedEnvelope<T>(Future<T> Function() body) async {
    final link = _link;
    if (link is! Ready) return body();
    final transport = link.info.transport;
    await transport.unsubscribeFromAdcFeed();
    await Future<void>.delayed(_feedPauseSettle);
    try {
      return await body();
    } finally {
      // Resume only if the same link is still up (a disconnect mid-write
      // already tore everything down).
      if (_link is Ready && identical(_link.transport, transport)) {
        try {
          await transport.subscribeToAdcFeed();
        } catch (_) {
          // Resume failed: the link would stay marked streaming with a dead
          // feed and no recovery path (nothing retries this subscription).
          // Tear it down — connect-time fails the same way when the feed
          // can't be subscribed (see [_runPostConnectSetup]).
          final name = link.info.displayName;
          _teardownLink(transport, releasePlatform: true);
          _events.emit(BleConnectionLost(name));
          notifyListeners();
          rethrow;
        }
      }
    }
  }

  /// Write the Settings-namespace device name ([kvsKeyDeviceName]) to the
  /// connected device; input is trimmed, and an empty (post-trim) input
  /// CLEARS the name — the device reverts to its factory name. Returns
  /// false when the device rejects the write (the local display name then
  /// stays put); throws on invalid input ([isValidDeviceName]) or missing
  /// link state. The display name updates only on device confirmation.
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

  /// How long the system enable-Bluetooth dialog may sit unanswered before
  /// the queued command gives up. The default [UniversalBle.timeout] (5 s) is
  /// shorter than a human reading a dialog.
  static const Duration _enableDialogTimeout = Duration(minutes: 2);

  /// Request everything a scan needs when the radio isn't usable: the runtime
  /// Bluetooth permissions first (a clean install doesn't hold them, and the
  /// enable intent is rejected with a SecurityException without
  /// BLUETOOTH_CONNECT), then the system enable-Bluetooth dialog. Throws when
  /// permissions are denied; a dismissed enable dialog completes normally
  /// with the radio still off.
  Future<void> _requestEnableBluetooth() async {
    if (kIsWeb) return;
    await UniversalBle.requestPermissions();
    // iOS/macOS have no enable API (Bluetooth is toggled in system settings).
    if (BleCapabilities.supportsBluetoothEnableApi) {
      await UniversalBle.enableBluetooth(timeout: _enableDialogTimeout);
    }
    await _updateBluetoothState();
  }

  void _onScanResult(BleDevice result) {
    // Keep all discovered devices; a repeat advertisement from a known device
    // always replaces the stored entry so the row shows the FRESHEST RSSI —
    // signal may weaken as well as strengthen. A null RSSI is kept as-is: on
    // native the row shows a transient "RSSI: --" until a reading lands, and
    // on web (where scan results never carry RSSI — see [supportsScanRssi])
    // the row omits the RSSI slot entirely. The one exception is the name:
    // plain ADV packets often omit it (it may only ride in the SCAN_RSP) and
    // some stacks deliver each PDU as a separate callback, so a nameless
    // re-advertisement must not blank the row title — keep the last known
    // name in that case.
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
    // A fresh advertisement is a fresh platform handle, so any recorded
    // connect failure for this device is moot (on web a scan result IS the
    // picker round-trip the row's failure hint tells the user to do).
    _connectFailures.remove(mapped.deviceId);
    notifyListeners();
    _syncFreshnessPoke(); // rows exist now — start ageing them if visible
    // Web: a scan result is not a passive advertisement — it is the device
    // the user just picked in Chrome's requestDevice() chooser (the popup IS
    // the scan). Treat it as an explicit connect request and end the scan.
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
    _syncFreshnessPoke(); // the list may have been cleared — stop the poke
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != BtAvailability.poweredOn) {
      // The Scan tap is the recovery point for an unusable radio: pop the
      // permission/enable prompts, then fall through if they worked. A
      // permission denial throws (the Devices tab toasts it); a dismissed
      // enable dialog leaves the radio off and we bail.
      await _requestEnableBluetooth();
      if (_bluetoothState != BtAvailability.poweredOn) {
        return;
      }
    }
    // A scan kick-off during the post-disconnect settle window does NOT
    // shorten the window (no pre-commitment — the picker may be cancelled,
    // and only a successful pick is settle evidence; see
    // [_connectPickedWebDevice]). A mid-teardown device simply doesn't appear
    // in the picker on web.
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
    // On web there is no passive scan — startScan is Chrome's requestDevice()
    // picker and yields exactly one result (the picked device) — so clearing
    // here would only ever delete previously-picked, still-connectable
    // devices (their handles live in universal_ble's device map for the page
    // session). Keep them: picks accumulate into a multi-device list and
    // [_onScanResult] dedupes a re-picked device by deviceId. Native keeps
    // fresh-scan semantics: clear on start so the list reflects what is
    // actually nearby now.
    //
    // The snapshot/restore covers a failed scan start (native radio error,
    // or a web picker cancel): the previously-discovered devices remain
    // connectable and a cancel should change nothing. On web the restore is
    // a no-op — nothing was cleared, and no result can precede a picker
    // throw.
    //
    // NOTE: on web a just-torn-down device stays listed inside the
    // reconnect-settle window, but its row's hint shows the embargo and
    // [linkBusy] keeps Connect disabled — a manual reconnect can't start
    // until the stamp expires (a scan kick-off no longer ends the window,
    // so the old disconnect → Scan → cancel → fast reconnect race is gone).
    final previousDevices = List<DiscoveredDevice>.of(_devices);
    if (!kIsWeb) {
      _devices.clear();
    }
    _isScanning = true;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [btServiceId]),
        platformConfig: PlatformConfig(
          // Web Bluetooth gates GATT access per service: the sampler service
          // comes from the picker filter; anything else discovered or
          // touched over GATT must be declared here (Device Information,
          // read during post-connect setup; OTA, touched by runOta).
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
        // A picker dismissal is a user choice, not a failure — the browser
        // already surfaced it. Swallow (state is rolled back above).
        debugPrint('Web scan picker closed without a selection: $e');
        return;
      }
      // A genuine failure (native radio error, or a non-dismissal web error):
      // the UI surfaces it (see _scanWithFeedback on the Devices tab).
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
  /// Runs for the link's whole streaming lifetime rather than only while an
  /// RSSI-showing tab is on screen.
  /// Cancels any previous poller first. Reads are best-effort: a failed read
  /// is swallowed silently and retried on the next tick.
  void _startRssiPolling(LinkTransport transport) {
    _stopRssiPolling();
    if (transport.isSimulated || !_supportsRssi) {
      return;
    }
    _rssiPollTimer = Timer.periodic(rssiPollInterval, (_) async {
      // Between ticks the link may have dropped or switched devices.
      if (!identical(_link.transport, transport) || !_link.isStreaming) {
        _stopRssiPolling();
        return;
      }
      try {
        final int rssi = await transport.readRssi();
        // Guard again: the link may have changed during the await.
        if (identical(_link.transport, transport) && _link.isStreaming) {
          _link.telemetry?.rssi = rssi;
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
  /// polling, supersede in-flight setup, dispose the transport, and reset the
  /// link to the idle sentinel. Recording is NOT handled here —
  /// [RecordingController] observes this notifier and stops its session when
  /// streaming ends.
  ///
  /// [releasePlatform] must be true when the platform-level link is (or may
  /// still be) up: a failed post-connect setup, or an abandoned/timed-out
  /// connect. It triggers a best-effort platform disconnect so the OS/browser
  /// connection can't leak. Local state is reset FIRST, so the resulting
  /// disconnect callback arrives to an unwanted link and is ignored by the
  /// guard in [_onConnectionChange].
  ///
  /// On web, tearing down a LIVE link also stamps the device's reconnect
  /// embargo (see [_reconnectNotBefore]): the link goes idle immediately, and
  /// [linkBusy] blocks the too-soon-reconnect race from there. A teardown
  /// while the link is still in `connecting` is a failed connect attempt —
  /// no live link ever came up, so nothing settles and NO stamp is made
  /// (parking such an attempt in the window would flash a fake "waiting
  /// after disconnect" hint for a device that never connected, and delay an
  /// immediate retry for nothing). Native stacks and simulated links don't
  /// exhibit the race and stamp nothing either. Does NOT call
  /// [notifyListeners] — callers do.
  void _teardownLink(LinkTransport transport, {bool releasePlatform = false}) {
    final previous = _link;
    // Supersede any in-flight post-connect setup pass so it bails out instead
    // of writing state for a link we're tearing down.
    _supersedeSetupPasses();
    // The transport dies with the link: abort pending KVS commands / stop the
    // demo feed. A fresh link gets a fresh transport.
    transport.dispose();
    _stopRssiPolling();

    if (kIsWeb &&
        !transport.isSimulated &&
        previous.state != BtLinkState.connecting) {
      _reconnectNotBefore[transport.deviceId] = DateTime.now().add(
        reconnectSettleDelay,
      );
      // See [_reconnectPoke]: decide nothing, only re-render at window end.
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

  void _onConnectionChange(String deviceId, bool isConnected, String? err) {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    // Unwanted-link guard: ignore any connection event that has no app-side
    // owner — events for a different device than the active link, or connected
    // events for OUR device arriving when no link is expected (idle —
    // including inside a pending reconnect-settle window — or closing). A
    // platform-level connect can complete AFTER we gave up on it (connect
    // timeout, user cancel); the GATT link is then live at the platform level
    // with nothing tracking it. Release such links so they can't leak, then
    // ignore the event.
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
      // The connect() continuation owns post-connect setup; a connected event
      // for the active link is expected and needs no action here.
      return;
    }

    // A disconnect event while a connect attempt is in flight is how NATIVE
    // stacks report a REFUSED connect: universal_ble delivers the refusal to
    // this handler synchronously, THEN completes the connect() future with an
    // error from that same event. Record the per-row failure marker here and
    // tear down — still in `connecting`, so no reconnect embargo is stamped
    // (no live link ever came up); the future's error then lands in
    // [_beginLink]'s catch, which finds the link already idle and returns
    // silently — exactly one marker for either failure flavor. A
    // user-requested cancel transitions through `disconnecting` first, so it
    // never records a marker here.
    if (_link is Connecting) {
      _connectFailures[deviceId] = ConnectFailureKind.failed;
      _teardownLink(_link.transport!);
      notifyListeners();
      return;
    }

    // Disconnect resolved (whether user-requested or unexpected): run the
    // common teardown (the platform side is already down, so no GATT
    // release), which stamps the device's reconnect-settle embargo on web
    // before returning the link to the idle sentinel.
    final Link link = _link;
    final String name = link.displayName;
    // An unexpected drop while the link was up (setting up, starting the
    // stream, or streaming) gets a user notice. User-requested disconnects
    // arrive here in `disconnecting`, and post-connect setup failures already
    // emitted BleConnectionFailed before tearing down — so neither
    // double-reports.
    final bool wasActive = link.isLinkUp;
    // Proof of life ends at teardown: stamp it so the row's "last
    // seen/connected" age starts counting from now, not from the (possibly
    // much older) connect time. Only the UNEXPECTED drop is stamped here —
    // a user-requested disconnect arrives in `disconnecting` (wasActive
    // false) and was already stamped in [disconnectSelectedDevice].
    if (wasActive) {
      _stampAlive(deviceId);
      // Remember the platform's drop reason for the row hint (when it gave
      // one); a reasonless drop clears any stale entry so it can't be
      // misattributed to this drop.
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

  /// Post-connect setup for a freshly-up link: reflect "Setting up…", then
  /// MTU (native) and service discovery, then "Reading board constants…" for
  /// the ADC config and connect-time flash read, then "Starting data stream…"
  /// for the ADC feed subscription that advances the link to the usable
  /// [BtLinkState.streaming] state.
  ///
  /// Runs as a cancellable pass over [token]. Every connect/disconnect/
  /// teardown supersedes outstanding tokens (see [_supersedeSetupPasses]);
  /// after every await the pass re-checks it and abandons silently — no state
  /// writes, no failure notice — when a newer attempt (or a teardown) moved
  /// on. If the device drops mid-setup (common when Chrome accepts a too-soon
  /// reconnect then tears it down), the transport calls throw ("Cannot
  /// discover services…") or time out via the command queue.
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

      // Device identity (DIS): static strings read once per link. Independent
      // of the sampler channel below and never fatal.
      setup.info = await transport.readDeviceInfo();
      if (!token.isCurrent) return;

      // Discovery done; the board constants (ADC config readback + the
      // connect-time flash read) are the "Reading board constants…" stage.
      // The KVS channel comes up BEFORE the ADC feed subscription: firmware
      // locks the KVS while the feed holds the device lock, so the flash read
      // must happen first.
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
      // label is read off the link at doc delivery time (see
      // [connectedDeviceName]).
      setup.storedName = await backend.readDeviceName();
      if (!token.isCurrent) return;
      notifyListeners();

      final snapshot = await backend.readKvsSnapshot();
      if (!token.isCurrent) return;
      // A strict parse failure is a value, not a link failure:
      // `DeviceFlash.fromKvs` yields an `InvalidBoardCalibration` and the
      // device streams raw counts with a warning. Transport/protocol
      // failures still throw to the catch below and tear the link down.
      final flash = DeviceFlash.fromKvs(snapshot, pgaGains: adcConfig.pgaGains);
      onDeviceFlash(flash);

      // Constants in; the ADC feed subscription is the "Starting data
      // stream…" stage.
      setup.phase = BtLinkState.subscribing;
      notifyListeners();

      await transport.subscribeToAdcFeed();
      if (!token.isCurrent) return;

      // Setup complete: adopt the link record and begin live RSSI polling for
      // the signal display.
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
      // A superseded pass failing is expected (the device was torn down or a
      // queued command was cancelled/timed out) — swallow it silently. Only a
      // genuine failure of the *current* attempt resets the link and toasts.
      if (!token.isCurrent) {
        debugPrint('Ignoring stale post-connect failure for $deviceId: $e');
        return;
      }
      debugPrint('Post-connect setup failed for $deviceId: $e');
      // The GATT link came up (connect succeeded) before setup failed —
      // that is a proof of life; stamp it before tearing down.
      _stampAlive(deviceId);
      // Release the platform link so it can't hold a connection the app
      // considers failed.
      _teardownLink(transport, releasePlatform: true);
      // Exact reason for the Devices-tab row; the user-facing toast stays
      // generic (see AppShellState).
      _setupFailures[deviceId] = '$e';
      _events.emit(BleConnectionFailed(transport.displayName));
      notifyListeners();
    }
  }

  /// Synchronous part of the connect preamble: refuse while [linkBusy] (a
  /// link mid-transition or active, or — on web — a device still inside its
  /// post-disconnect settle window — so we never start a connect against a
  /// link the stack isn't ready for) and supersede any lingering setup pass
  /// from a prior attempt.
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
    if (linkBusy) {
      return false;
    }
    // A new attempt supersedes every recorded failure marker.
    _connectFailures.clear();
    _lastDisconnectErrors.clear();
    _setupFailures.clear();
    _supersedeSetupPasses();
    return true;
  }

  /// Drive one connect through the shared lifecycle: mark the link
  /// connecting, stop any scan, bring the transport up, then run post-connect
  /// setup. Real BLE and the demo differ only in their [LinkTransport].
  Future<void> _beginLink(LinkTransport transport) async {
    if (!_beginConnect()) return;
    _link = Connecting(transport);
    notifyListeners();

    try {
      // Stop scanning before connecting (the package advises it). The busy
      // state is already written above, so this await can't reopen the
      // Scan-tap race. A stopScan failure must not wedge the link in
      // `connecting` — it fails the attempt like any other connect failure.
      if (_isScanning) {
        await _stopScan();
      }
      await transport.connect();
    } catch (e) {
      // This attempt was abandoned while its future was outstanding (user
      // cancel, superseded by a newer one, or a refusal that already arrived
      // via the connection-change callback — see the `connecting` case in
      // [_onConnectionChange], which recorded the marker and tore down):
      // the teardown already ran, so fail quietly instead of running a second
      // teardown, recording a duplicate marker, or surfacing an error the
      // user asked for.
      if (_link is! Connecting || _link.deviceId != transport.deviceId) {
        return;
      }
      // Record the failure kind for the Devices tab's per-row marker — the
      // user-facing channel for this failure (no toast). Go through the
      // common teardown (not a bare reset): it supersedes any lingering setup
      // pass and releases the platform link (a timed-out connect can still
      // complete later — the guard in [_onConnectionChange] handles that
      // callback). The link is still in `connecting` here, so the teardown
      // stamps NO reconnect embargo: the attempt never had a live link to
      // settle.
      _connectFailures[transport.deviceId] = e is TimeoutException
          ? ConnectFailureKind.timeout
          : ConnectFailureKind.failed;
      _teardownLink(transport, releasePlatform: true);
      notifyListeners();
      rethrow;
    }

    // A cancellation/refusal callback may have torn the attempt down during
    // connect; only start setup for a link still connecting.
    if (_link is! Connecting || _link.deviceId != transport.deviceId) {
      return;
    }
    unawaited(
      _runPostConnectSetup(_setupTokenFor(transport.deviceId), transport),
    );
  }

  Future<void> connectToDemoDevice() async {
    final demo = _demo;
    // The demo row's Connect is always wired (see main), so a null [_demo]
    // is a test-harness artifact.
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

  /// Web only: connect to a device the user just picked in Chrome's
  /// requestDevice() chooser (see [_onScanResult]). [connectToDevice] stops
  /// the scan itself before connecting.
  Future<void> _connectPickedWebDevice(DiscoveredDevice device) async {
    // The pick is the teardown-settle signal Web Bluetooth otherwise lacks:
    // tested on Chrome, a device mid-GATT-teardown does not appear in the
    // picker at all (it resurfaces only once it resumes advertising), so a
    // successful pick means the stack is ready. Clear any pending reconnect
    // embargo unconditionally — as the old early-finish path did — rather
    // than waiting it out. (A scan kick-off does NOT clear it, so the manual
    // reconnect race on a never-re-picked device stays closed.)
    _reconnectNotBefore.clear();
    _reconnectPoke?.cancel();
    _reconnectPoke = null;
    try {
      // Refuses silently if the link has meanwhile become busy (e.g. the user
      // tapped Connect on another row or started the demo device) — the
      // user's later action wins.
      await connectToDevice(device.deviceId);
    } catch (e) {
      // connectToDevice already tore the failed attempt down and recorded
      // the per-row failure marker — the single user-facing channel for
      // connect failures (deliberately NO toast here; see connectToDevice).
      debugPrint('Auto-connect to ${device.deviceId} failed: $e');
    }
  }

  Future<void> disconnectSelectedDevice() async {
    // Allow disconnecting whenever a link attempt is in flight or the GATT
    // link is up — connecting (cancel a stuck/hung attempt), setting up, or
    // streaming. The teardown releases the platform side; a connect that
    // completes after we gave up on it is caught by the unwanted-link guard
    // in [_onConnectionChange].
    final Link link = _link;
    final LinkTransport? transport = link.transport;
    if (transport == null) return;
    if (link is! Connecting && !link.isLinkUp) return;
    final String deviceId = transport.deviceId;
    final String deviceName = link.displayName;
    // Supersede any in-flight post-connect setup pass immediately so it stops
    // mutating state while we tear the link down.
    _supersedeSetupPasses();

    // A live link being torn down on request is proof of life up to this
    // moment — stamp it so the row's "last seen/connected" age counts from
    // the disconnect, not from the last advertisement (native: minutes old
    // if the scan stopped at connect) or the connect time (web: no adverts
    // exist, so the stamp is all there is). The connection-change callback
    // can't do this: by the time it runs, the state is already
    // `disconnecting`, so its `wasActive` check is false. A cancelled
    // connect attempt (connecting, never up) stamps nothing: a refused
    // attempt proves nothing about the device being alive.
    if (link.isLinkUp) {
      _stampAlive(deviceId);
    }
    _link = Closing(transport);
    notifyListeners();

    // The transport's disconnect applies [disconnectTimeout] and (for BLE)
    // drives our [_onConnectionChange] handler, which is the single place the
    // link is reset to idle. After it resolves, reconcile: if the link is
    // still closing on this device, the platform never confirmed — force idle
    // and surface the notice ourselves. A simulated transport settles
    // immediately with no platform to confirm.
    await transport.disconnect();
    // Workaround for a universal_ble bug: its disconnect path can leave the
    // availability stream stale without this extra query.
    if (!transport.isSimulated) {
      await UniversalBle.getBluetoothAvailabilityState();
    }
    if (_link is Closing && _link.deviceId == deviceId) {
      // A simulated transport settles with no platform to confirm; that is
      // expected, not a timeout.
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

  /// ADC-feed path shared by GATT notifications and the demo timer: record
  /// the notification size, then hand the bytes to [_onAdcData]. Notifies
  /// only when min/max change so the connection-info card can update
  /// without a rebuild on every packet.
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
    // Three characteristics can carry notifications on a link: the ADC feed
    // (while streaming), the KVS channel (for KVS frames), and — only during
    // a flash session — the OTA control characteristic. Drop anything else
    // (a stale notification from a torn-down link) so foreign bytes are never
    // parsed. universal_ble normalizes characteristicId to lowercase before
    // invoking this callback, and all ids are already lowercase, so an exact
    // match is safe. Multi-device: route by deviceId instead of dropping.
    if (deviceId != _link.deviceId) {
      logTrace(
        () =>
            'Dropping notification from unexpected device $deviceId, '
            'characteristic $characteristicId (${data.length} B); '
            'active link is ${_link.deviceId.isEmpty ? '(none)' : _link.deviceId}',
      );
      return;
    }
    // Feed packets go straight to the protocol layer, KVS frames to the KVS
    // client, OTA control frames to the live flash session; the link manager
    // never interprets bytes itself.
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

  /// Tear down this (now stale) generation's BLE link after a hot restart on
  /// web. Invoked by the NEXT generation's `main()` via the hot-restart
  /// cleanup hook (see `hot_restart_cleanup_web.dart`) — browser-side BLE
  /// notification listeners and timers survive a web hot restart, so without
  /// this the old decoder/DataHub keep running and try to render into the
  /// disposed engine view.
  ///
  /// Order matters: the per-packet data callbacks are silenced FIRST
  /// (synchronously) so the notifyListeners → scheduleFrame chain stops
  /// immediately; the async platform teardown then releases the browser-level
  /// connection so the new generation can find and reconnect the device.
  /// [onDeviceFlash] is constructor-injected and not silenced here: it fires
  /// only from a post-connect setup pass, which [_supersedeSetupPasses]
  /// (below, before the first await) makes bail before reaching it.
  /// Deliberately does NOT call [notifyListeners] — the only listeners are
  /// the disposed widget tree.
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
    // Supersede any in-flight post-connect setup pass so it bails out.
    _supersedeSetupPasses();

    // Best-effort from here: the app is being torn down, so failures are
    // irrelevant — just make sure they can't propagate.
    try {
      if (_isScanning) {
        await UniversalBle.stopScan();
      }
      if (transport != null && !transport.isSimulated && _link.isLinkUp) {
        await transport.disconnect();
      }
    } catch (_) {
      // Swallow: stale-generation teardown must never surface errors.
    }
  }
}
