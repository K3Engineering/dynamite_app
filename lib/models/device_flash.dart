import 'board_calibration.dart';
import 'load_cell.dart';

// ---------------------------------------------------------------------------
// The device flash document: the factory board calibration (read-only to
// the app) plus the app-writable load cell slots, as the one `key=value`
// document the device's KVS holds. The per-channel join of the two halves
// ([ChannelCalibration]) that the unit layer consumes lives in
// channel_calibration.dart; the line parser itself ([parseFlashKv]) lives
// with the board file, the document's original content.
//
// The app OWNS the slot keys and only those: a save SETs/DELs `lc*` keys in
// the User namespace and never touches the board half (or any other key) —
// see `KvsFlashTransport.writeSlots`.
// ---------------------------------------------------------------------------

/// The device flash document: the factory board calibration (read-only to
/// the app) plus the app-writable load cell slots.
class DeviceFlash {
  DeviceFlash({required this.board, required this.slots});

  final BoardCalibration board;
  final RigSlots slots;

  /// Parse a whole flash document, reassembled from the device KVS.
  /// [pgaGains] is the ADC's GAIN-register readback for board-constant
  /// resolution — always present: an unreadable ADC config fails the
  /// connection upstream (see `BleLinkManager`).
  ///
  /// Throws [FormatException] on present-but-invalid content (see
  /// [BoardCalibration.fromKv] and [RigSlots.fromKv]): a document the app
  /// can't fully make sense of fails the connect-time read rather than
  /// degrading into an instrument that hides the corruption — and into a
  /// save that would delete the corrupt-but-recoverable keys. An EMPTY
  /// document is legal (an unprovisioned unit). Unknown keys are ignored:
  /// they are not the app's data, and the app's writes never touch them.
  factory DeviceFlash.parse(String text, {required List<double> pgaGains}) {
    final kv = parseFlashKv(text);
    return DeviceFlash(
      board: BoardCalibration.fromKv(kv, pgaGains: pgaGains),
      slots: RigSlots.fromKv(kv),
    );
  }
}
