import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_info.dart';
import '../models/firmware_release.dart';
import 'app_events.dart';
import 'ble_link_manager.dart';
import 'firmware_catalog.dart';

/// One release-check result against the connected device.
@immutable
class FirmwareCheck {
  const new({
    required this.channel,
    required this.board,
    required this.installedDescribe,
    required this.candidates,
  });

  /// The channel the check resolved for; its result is only valid for this one.
  final FirmwareChannel channel;

  /// The board the check ran for (firmware-rev prefix).
  final String board;

  /// The device's installed identity (git-describe from the DIS read).
  final String installedDescribe;

  /// Every flashable release the catalog offered at check time, newest first.
  /// The update screen's version picker is this same list, so browsing "other
  /// versions" costs no second fetch and can't show a release the channel
  /// logic would refuse.
  final List<FirmwareRelease> candidates;

  /// The channel's target among [candidates]; null when the channel has
  /// nothing (nothing published yet, or only prereleases on stable).
  FirmwareRelease? get target =>
      selectFirmwareTarget(candidates, channel: channel);

  /// An update (of any direction — the offer rule is "differs, flash the
  /// channel target") is worth offering.
  bool get differsFromDevice {
    final target = this.target;
    return target != null && !describeMatchesTag(installedDescribe, target.tag);
  }
}

/// The release-check lifecycle. One state at a time, so illegal
/// combinations (a result alongside a failure) are unrepresentable. Only
/// [CheckOk] carries a result; a failed re-check blanks the prior target.
@immutable
sealed class FirmwareCheckState {
  const new();
}

/// No check has produced a result for the current link (app start, the
/// disconnect reset in [FirmwareUpdateService], or a firmware revision
/// [FirmwareUpdateService.checkForUpdates] could not parse and skipped).
class CheckNeverRan extends FirmwareCheckState {
  const new();
}

/// A check is fetching; its outcome replaces this state.
class CheckRunning extends FirmwareCheckState {
  const new();
}

/// The check completed; [result] is the comparison of the device's
/// installed firmware against the channel target.
class CheckOk extends FirmwareCheckState {
  const new(this.result);
  final FirmwareCheck result;
}

/// The check failed: fetch trouble (see
/// [FirmwareUpdateService.checkForUpdates]).
class CheckFailed extends FirmwareCheckState {
  const new(this.error);
  final Object error;
}

/// Owns everything about release checks: the user's channel (persisted), the
/// release-check state ([checkState]), the once-per-connect background check,
/// and the post-flash verdict (see [noteFlashAccepted]). The flash itself
/// belongs to the update screen; this only answers "what should the device be
/// running?". [link] is listened to from the constructor — construction is the
/// wiring.
class FirmwareUpdateService extends ChangeNotifier {
  new({
    required this._prefs,
    required this._link,
    required this._events,
    required this.catalog,
  }) {
    _channel = FirmwareChannel.fromName(_prefs.getString(_keyChannel));
    _link.addListener(_maybeAutoCheck);
  }

  static const _keyChannel = 'firmware_channel';

  final SharedPreferences _prefs;
  final BleLinkManager _link;
  final AppEvents _events;

  // Mutable so the update screen can substitute a fake catalog in tests.
  FirmwareCatalog catalog;

  /// Held high for a flash's whole duration; the wakelock policy takes it
  /// as a second keep-awake input (the feed is unsubscribed during a flash,
  /// which would otherwise clear the streaming-based hold).
  final ValueNotifier<bool> flashInProgress = ValueNotifier(false);

  FirmwareChannel _channel = FirmwareChannel.stable;
  FirmwareChannel get channel => _channel;

  /// The one piece of mutable check data; every transition is a single
  /// assignment (see [FirmwareCheckState]).
  FirmwareCheckState checkState = const CheckNeverRan();

  /// The device id the background check already ran for; reset on link
  /// drop. Only this background path consults it — UI-triggered checks
  /// always run.
  String? _checkedForDevice;

  /// The release tag a just-completed flash claims to have installed and the
  /// device it was flashed onto, held until a successful check of that device
  /// proves or disproves it (see [noteFlashAccepted]).
  ({String deviceId, String tag})? _pendingFlash;

  /// Record that the connected device accepted a flash of [tag], set by the
  /// update screen when its flash returns. The device reboots on its own, so
  /// the verdict rides the next check of that device (typically the
  /// reconnect's auto-check) rather than a screen staying open: a match emits
  /// [FirmwareFlashVerified] and the pend is consumed either way (a mismatch
  /// raises the update-available banner). The pend is keyed by device because
  /// fleet boards tend to run the channel target, so a check of any OTHER
  /// board would "verify" a flash it never saw. A from-file flash records
  /// nothing — no identity to compare.
  void noteFlashAccepted(String tag) {
    _pendingFlash = (deviceId: _link.connectedDeviceId, tag: tag);
  }

  Future<void> setChannel(FirmwareChannel channel) async {
    if (channel == _channel) return;
    _channel = channel;
    if (checkState case CheckOk(:final result)) {
      checkState = CheckOk(
        FirmwareCheck(
          channel: channel,
          board: result.board,
          installedDescribe: result.installedDescribe,
          candidates: result.candidates,
        ),
      );
    }
    notifyListeners();
    await _prefs.setString(_keyChannel, channel.name);
  }

  /// Check the connected device against the release catalog. No-op while a
  /// check is running, on a simulated link (the demo device has no real
  /// revision to parse), without a link, or when the revision does not parse
  /// as `<board>|<version>` — that string is firmware-built, so a non-match
  /// is a board this catalog knows nothing about, not a failure to surface.
  Future<void> checkForUpdates() async {
    if (checkState is CheckRunning) return;
    if (_link.linkIsSimulated) return;
    final info = _link.connectedDeviceInfo;
    if (info == null) return;
    final rev = parseFirmwareRev(info.firmwareRev);
    if (rev == null) return;
    // Snapshot link inputs; the worker must not re-read them after it suspends.
    await _runCheck(info: info, rev: rev, deviceId: _link.connectedDeviceId);
  }

  Future<void> _runCheck({
    required DeviceInfo info,
    required ({String board, String describe}) rev,
    required String deviceId,
  }) async {
    checkState = const CheckRunning();
    notifyListeners();

    List<FirmwareRelease>? candidates;
    Object? error;
    try {
      candidates = await catalog.available();
    } catch (e) {
      error = e;
    }

    // The link can drop mid-fetch; one DeviceInfo per connection means
    // identity rejects a stale result before it can overwrite the
    // disconnect reset to [CheckNeverRan].
    if (!identical(_link.connectedDeviceInfo, info)) return;

    if (candidates != null) {
      final check = FirmwareCheck(
        channel: _channel,
        board: rev.board,
        installedDescribe: rev.describe,
        candidates: candidates,
      );
      checkState = CheckOk(check);
      final pending = _pendingFlash;
      if (pending != null && pending.deviceId == deviceId) {
        _pendingFlash = null;
        if (describeMatchesTag(check.installedDescribe, pending.tag)) {
          _events.emit(FirmwareFlashVerified(check.installedDescribe));
        }
      }
    } else {
      checkState = CheckFailed(error!);
    }
    notifyListeners();
  }

  /// The background check: once per GATT link, after the DIS identity read
  /// lands. Simulated links and re-notifies of the same link are skipped.
  void _maybeAutoCheck() {
    final deviceId = _link.connectedDeviceId;
    if (deviceId.isEmpty) {
      _checkedForDevice = null;
      checkState = const CheckNeverRan();
      notifyListeners();
      return;
    }
    if (_link.linkIsSimulated || _link.connectedDeviceInfo == null) return;
    if (_checkedForDevice == deviceId) return;
    _checkedForDevice = deviceId;
    unawaited(checkForUpdates());
  }
}
