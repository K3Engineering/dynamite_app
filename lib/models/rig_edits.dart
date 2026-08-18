import 'load_cell.dart';

/// A "last seen values" entry: a cell this app has met (on a device flash
/// read, or typed in by the user), offered as a quick pick when filling an
/// empty slot. Purely advisory app memory — the device is the rig's truth.
class RigHistoryEntry {
  RigHistoryEntry({
    required this.cell,
    required this.lastSeen,
    required this.deviceName,
  });

  final LoadCellProfile cell;
  DateTime lastSeen;

  /// Device the entry was last seen on (or added on), for display.
  String deviceName;

  Map<String, dynamic> toJson() => {
    'cell': cell.toJson(),
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'deviceName': deviceName,
  };

  /// Tolerant of extra keys (older versions persisted an 'origin' field).
  factory RigHistoryEntry.fromJson(Map<String, dynamic> json) =>
      RigHistoryEntry(
        cell: LoadCellProfile.fromJson(
          Map<String, dynamic>.from(json['cell'] as Map),
        ),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int),
        deviceName: json['deviceName'] as String? ?? '',
      );
}

/// Unsaved slot edits. In-memory ONLY (never persisted): they survive a
/// device disconnect for the SAME device (restored on reconnect, see
/// `RigState.onFlashRead`), but an app restart drops them — by design, so a
/// stale edit can never resurface days later against an unknown rig.
class PendingRigEdits {
  PendingRigEdits({
    required this.deviceId,
    required this.base,
    required this.edited,
  });

  final String deviceId;

  /// The flash state the edits are based on. If a reconnect finds the device
  /// no longer matches this, the edits are stale and get discarded.
  final RigSlots base;

  /// The edited slot list (what the app's readings already use).
  RigSlots edited;
}
