import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/firmware_release.dart';
import 'app_events.dart';
import 'ble_link_manager.dart';
import 'firmware_catalog.dart';

/// One release-check result against the connected device.
class FirmwareCheck {
  const FirmwareCheck({
    required this.board,
    required this.installedDescribe,
    required this.channel,
    required this.target,
    required this.when,
  });

  /// The board the check ran for (firmware-rev prefix).
  final String board;

  /// The device's installed identity (git-describe from the DIS read).
  final String installedDescribe;
  final FirmwareChannel channel;

  /// The channel's current target for this board; null when no release
  /// applies (nothing published yet, or nothing for this board).
  final FirmwareRelease? target;

  final DateTime when;

  /// An update (of any direction — the offer rule is "differs, flash the
  /// channel target") is worth offering.
  bool get differsFromDevice =>
      target != null && !describeMatchesTag(installedDescribe, target!.tag);
}

/// Owns everything about release checks: the user's channel (persisted),
/// the last check result, and the once-per-connect background check that
/// raises the [FirmwareUpdateAvailable] banner. The flash orchestration
/// itself belongs to the update screen; this service only answers "what
/// should the device be running?".
///
/// Wiring matches the other reactive services: [link] is listened to from
/// the constructor — construction is the wiring.
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

  FirmwareCheck? check;
  bool checking = false;

  /// The last check's failure ([StateError] on fetch/parse trouble). Cleared
  /// on the next attempt; the screen surfaces it, never a silent "no
  /// release".
  Object? checkError;

  /// The device id the background check already ran for; reset on link
  /// drop. Manual checks bypass it.
  String? _checkedForDevice;

  /// The target tag already bannered, so a re-check finding the same
  /// difference doesn't stack a second snackbar.
  String? _announcedTarget;

  Future<void> setChannel(FirmwareChannel channel) async {
    if (channel == _channel) return;
    _channel = channel;
    notifyListeners();
    await _prefs.setString(_keyChannel, channel.name);
    // The channel is part of every check's input; a stale result for the
    // other channel is worse than none.
    if (_link.connectedDeviceInfo != null) unawaited(checkForUpdates());
  }

  /// Check the connected device against the release catalog. No-op when a
  /// check is already running or no device identity is available.
  Future<void> checkForUpdates({bool manual = false}) async {
    if (checking) return;
    final info = _link.connectedDeviceInfo;
    final rev = info?.firmwareRev == null
        ? null
        : parseFirmwareRev(info!.firmwareRev!);
    if (rev == null) {
      if (manual) {
        checkError = StateError(
          'Cannot parse the device firmware revision '
          '(${info?.firmwareRev ?? 'unread'}) — expected "<board>|<version>".',
        );
        notifyListeners();
      }
      return;
    }
    checking = true;
    checkError = null;
    notifyListeners();
    try {
      final target = await catalog.latestFor(channel: _channel);
      check = FirmwareCheck(
        board: rev.board,
        installedDescribe: rev.describe,
        channel: _channel,
        target: target,
        when: DateTime.now(),
      );
      if (check!.differsFromDevice) {
        final tag = target!.tag;
        if (tag != _announcedTarget) {
          _announcedTarget = tag;
          _events.emit(
            FirmwareUpdateAvailable(
              deviceName: _link.connectedDeviceName,
              installedDescribe: rev.describe,
              targetTag: tag,
            ),
          );
        }
      } else {
        _announcedTarget = null;
      }
    } catch (e) {
      checkError = e;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// The background check: once per GATT link, after the DIS identity read
  /// lands. Simulated links and re-notifies of the same link are skipped.
  void _maybeAutoCheck() {
    final deviceId = _link.connectedDeviceId;
    if (deviceId.isEmpty) {
      _checkedForDevice = null;
      _announcedTarget = null;
      check = null;
      checkError = null;
      notifyListeners();
      return;
    }
    if (_link.linkIsSimulated || _link.connectedDeviceInfo == null) return;
    if (_checkedForDevice == deviceId) return;
    _checkedForDevice = deviceId;
    unawaited(checkForUpdates());
  }
}
