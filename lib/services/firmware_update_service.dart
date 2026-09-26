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
  const FirmwareCheck({
    required this.board,
    required this.installedDescribe,
    required this.target,
  });

  /// The board the check ran for (firmware-rev prefix).
  final String board;

  /// The device's installed identity (git-describe from the DIS read).
  final String installedDescribe;

  /// The channel's current target for this board; null when no release
  /// applies (nothing published yet, or nothing for this board).
  final FirmwareRelease? target;

  /// An update (of any direction — the offer rule is "differs, flash the
  /// channel target") is worth offering.
  bool get differsFromDevice =>
      target != null && !describeMatchesTag(installedDescribe, target!.tag);
}

/// The release-check lifecycle. One state at a time, so illegal
/// combinations (a result alongside a failure) are unrepresentable. Only
/// [CheckOk] carries a result; a failed re-check blanks the prior target.
@immutable
sealed class FirmwareCheckState {
  const FirmwareCheckState();
}

/// No check has produced a result for the current link (app start, the
/// disconnect reset in [FirmwareUpdateService], or a firmware revision
/// [FirmwareUpdateService.checkForUpdates] could not parse and skipped).
class CheckNeverRan extends FirmwareCheckState {
  const CheckNeverRan();
}

/// A check is fetching; its outcome replaces this state.
class CheckRunning extends FirmwareCheckState {
  const CheckRunning();
}

/// The check completed; [result] is the comparison of the device's
/// installed firmware against the channel target.
class CheckOk extends FirmwareCheckState {
  const CheckOk(this.result);
  final FirmwareCheck result;
}

/// The check failed: fetch trouble (see
/// [FirmwareUpdateService.checkForUpdates]).
class CheckFailed extends FirmwareCheckState {
  const CheckFailed(this.error);
  final Object error;
}

/// Owns everything about release checks: the user's channel (persisted), the
/// release-check state ([checkState]), the once-per-connect background check
/// that raises the [FirmwareUpdateAvailable] banner, and the post-flash
/// verdict (see [noteFlashAccepted]). The flash itself belongs to the update
/// screen; this only answers "what should the device be running?". [link] is
/// listened to from the constructor — construction is the wiring.
class FirmwareUpdateService extends ChangeNotifier {
  FirmwareUpdateService({
    required SharedPreferences prefs,
    required BleLinkManager link,
    required AppEvents events,
    required this.catalog,
  }) : _prefs = prefs,
       _link = link,
       _events = events {
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

  /// The target tag already bannered, so a re-check finding the same
  /// difference doesn't stack a second snackbar.
  String? _announcedTarget;

  /// The release tag a just-completed flash claims to have installed, held
  /// until the next successful check proves or disproves it (see
  /// [noteFlashAccepted]).
  String? _pendingFlashTag;

  /// Record that the device accepted a flash of [tag], set by the update screen
  /// when its flash returns. The device reboots on its own, so the verdict
  /// rides the next check (typically the reconnect's auto-check) rather than a
  /// screen staying open: a match emits [FirmwareFlashVerified] and the pend is
  /// consumed either way (a mismatch raises the update-available banner). A
  /// from-file flash records nothing — no identity to compare.
  void noteFlashAccepted(String tag) {
    _pendingFlashTag = tag;
  }

  Future<void> setChannel(FirmwareChannel channel) async {
    if (channel == _channel) return;
    // A check's result is only valid for the channel it started on.
    if (checkState is CheckRunning) {
      throw StateError('Cannot switch channel while a check is running.');
    }
    _channel = channel;
    notifyListeners();
    await _prefs.setString(_keyChannel, channel.name);
    // The channel is part of every check's input; a stale result for the
    // other channel is worse than none.
    if (_link.connectedDeviceInfo != null) unawaited(checkForUpdates());
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
    // Snapshot inputs; the worker must not re-read fields after it suspends.
    await _runCheck(channel: _channel, info: info, rev: rev);
  }

  Future<void> _runCheck({
    required FirmwareChannel channel,
    required DeviceInfo info,
    required ({String board, String describe}) rev,
  }) async {
    checkState = const CheckRunning();
    notifyListeners();

    FirmwareCheckState outcome;
    FirmwareCheck? check;
    try {
      check = FirmwareCheck(
        board: rev.board,
        installedDescribe: rev.describe,
        target: await catalog.latestFor(channel: channel),
      );
      outcome = CheckOk(check);
    } catch (e) {
      outcome = CheckFailed(e);
    }

    // The link can drop mid-fetch; one DeviceInfo per connection means
    // identity rejects a stale result before it can overwrite the
    // disconnect reset to [CheckNeverRan].
    if (!identical(_link.connectedDeviceInfo, info)) return;

    checkState = outcome;
    if (check != null) {
      final pending = _pendingFlashTag;
      _pendingFlashTag = null;
      if (pending != null &&
          describeMatchesTag(check.installedDescribe, pending)) {
        _events.emit(FirmwareFlashVerified(check.installedDescribe));
      }
      if (check.differsFromDevice) {
        final tag = check.target!.tag;
        if (tag != _announcedTarget) {
          _announcedTarget = tag;
          _events.emit(
            FirmwareUpdateAvailable(deviceName: _link.connectedDeviceName),
          );
        }
      } else {
        _announcedTarget = null;
      }
    }
    notifyListeners();
  }

  /// The background check: once per GATT link, after the DIS identity read
  /// lands. Simulated links and re-notifies of the same link are skipped.
  void _maybeAutoCheck() {
    final deviceId = _link.connectedDeviceId;
    if (deviceId.isEmpty) {
      _checkedForDevice = null;
      _announcedTarget = null;
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
