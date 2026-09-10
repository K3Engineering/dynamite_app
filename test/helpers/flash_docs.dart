import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/demo_calibration.dart' show demoKvs;

export 'package:dynamite_app/services/demo_calibration.dart' show demoKvs;

/// Test-only view of the legacy `key=value` flash-document format. The wire
/// form is the folder-separated KVS ([KvsSnapshot]); production never parses
/// text, but fixtures are easier to read (and to mutate with `replaceFirst`)
/// as lines. The routing here mirrors the firmware layout: exact slot keys to
/// User, everything else to Factory.

/// The demo fixture as a legacy document, derived from [demoKvs] so tests
/// that mutate text can't drift from the production store.
final String demoBoardCalibrationDoc = [
  for (final e in {...demoKvs.factory, ...demoKvs.user}.entries)
    '${e.key}=${e.value}',
].join('\n');

/// Split a `key=value` document into a map. Lines without `key=value` shape
/// (version token, END marker, comments) are ignored; values may contain `=`
/// (split at the first one).
Map<String, String> parseFlashKv(String text) {
  final kv = <String, String>{};
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    kv[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return kv;
}

/// Folder-route a legacy document into a [KvsSnapshot].
KvsSnapshot kvsFromDoc(String text) {
  final factory = <String, String>{};
  final user = <String, String>{};
  for (final e in parseFlashKv(text).entries) {
    (rigSlotKeys.contains(e.key) ? user : factory)[e.key] = e.value;
  }
  return KvsSnapshot(factory: factory, user: user);
}

/// Parse a whole legacy document into a [DeviceFlash].
DeviceFlash flashFromDoc(String text, {required List<double> pgaGains}) =>
    DeviceFlash.fromKvs(kvsFromDoc(text), pgaGains: pgaGains);

/// Parse a board-only legacy document into a [BoardCalibration].
BoardCalibration boardFromDoc(String text, {required List<double> pgaGains}) =>
    BoardCalibration.fromKv(parseFlashKv(text), pgaGains: pgaGains);
