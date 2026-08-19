import 'board_calibration.dart';
import 'device_profile.dart';
import 'load_cell.dart';

// ---------------------------------------------------------------------------
// The device flash document: the factory board calibration (read-only to
// the app) plus the app-writable load cell slots, assembled into the one
// `key=value` document the calibration characteristic carries. The
// per-channel join of the two halves ([ChannelCalibration]) that the unit
// layer consumes lives in channel_calibration.dart; the line parser itself
// ([parseFlashKv]) lives with the board file, the document's original
// content.
// ---------------------------------------------------------------------------

/// Keys outside this set (a newer firmware's keys, another tool's metadata)
/// are NOT ours — they are kept verbatim in [DeviceFlash.extraLines] so a
/// save can't erase them.
final Set<String> _knownFlashKeys = {
  'cal.date',
  'cal.exc.mv',
  'cal.board',
  'cal.tool',
  'cal.origin',
  'cal.temp',
  'cal.adc',
  for (int i = 0; i < kAdcChannelCount; ++i) ...['ch$i.r', 'ch$i.raw'],
  for (int i = 0; i < kRigSlotCount; ++i) ...[
    'lc$i.name',
    'lc$i.cap',
    'lc$i.sens',
    'lc$i.mtime',
  ],
};

/// The full device flash document: the factory board calibration (read-only
/// to the app) plus the app-writable load cell slots. This is the unit the
/// calibration characteristic reads and writes.
class DeviceFlash {
  DeviceFlash({
    required this.board,
    required this.slots,
    List<String>? extraLines,
  }) : extraLines = List.unmodifiable(extraLines ?? const []);

  final BoardCalibration board;
  final RigSlots slots;

  /// Lines from the parsed document whose keys the model doesn't know, in
  /// original order, re-emitted verbatim by [serialize]. The app is the
  /// courier of the whole document, not just the keys it understands: a
  /// save must never silently erase flash content written by newer firmware
  /// or other tools.
  final List<String> extraLines;

  /// Parse a whole flash document. Never throws: structural problems degrade
  /// only the affected piece (a corrupt or partial calibration → uncalibrated
  /// board, slot → empty). Unknown `key=value` lines are preserved in
  /// [extraLines]. [pgaGains] is the ADC's GAIN-register readback for
  /// board-constant resolution — always present: an unreadable ADC config
  /// fails the connection upstream (see `BleLinkManager`).
  factory DeviceFlash.parse(String text, {required List<double> pgaGains}) {
    final kv = parseFlashKv(text);
    return DeviceFlash(
      board: BoardCalibration.fromKv(kv, pgaGains: pgaGains),
      slots: RigSlots.fromKv(kv),
      extraLines: [
        for (final rawLine in text.split(RegExp(r'\r?\n')))
          if (rawLine.trim().contains('='))
            if (!_knownFlashKeys.contains(
              rawLine.trim().substring(0, rawLine.trim().indexOf('=')).trim(),
            ))
              rawLine.trim(),
      ],
    );
  }

  /// Serialize the whole document. The app only ever writes with [slots] it
  /// intends to persist and [board] exactly as read — board keys round-trip
  /// verbatim (the app is not their owner, just their courier), and unknown
  /// keys ride along in [extraLines].
  String serialize() {
    final b = StringBuffer('K3CAL1\n');
    if (board.factoryDate != null) b.writeln('cal.date=${board.factoryDate}');
    if (board.excitationMv != null) {
      b.writeln('cal.exc.mv=${board.excitationMv}');
    }
    if (board.calBoardId != null) b.writeln('cal.board=${board.calBoardId}');
    if (board.calTool != null) b.writeln('cal.tool=${board.calTool}');
    if (board.calOrigin != null) b.writeln('cal.origin=${board.calOrigin}');
    final temps = board.calTempsC;
    if (temps != null) b.writeln('cal.temp=${temps.dut},${temps.calBoard}');
    final adc = board.calAdcGains;
    if (adc != null) b.writeln('cal.adc=${adc.join(',')}');
    for (int i = 0; i < board.channels.length; ++i) {
      final ch = board.channels[i];
      // Ladder and readings are one datum (see ChannelBoardCalibration):
      // both written for a calibrated channel, neither otherwise.
      final r = ch.readings;
      if (r != null) {
        b.writeln('ch$i.r=${ch.resistors!.join(',')}');
        b.writeln('ch$i.raw=${r.join(',')}');
      }
    }
    for (final line in extraLines) {
      b.writeln(line);
    }
    slots.serializeInto(b);
    b.write('END');
    return b.toString();
  }
}
