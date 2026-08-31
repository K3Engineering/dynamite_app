/// Session ids (the session directory names) look like
/// `2026-08-28T14-30-12-x7f2`: a fixed-width local wall-clock timestamp
/// (colons replaced by dashes for path-safety) plus a short random suffix.
/// Lexical order is chronological order. The suffix — not the timestamp —
/// carries uniqueness: same-second creates and backward clock jumps would
/// silently merge two sessions into one directory otherwise, and uniqueness
/// must be a property of the format, not of how the app behaves.
/// `sessions_root/id/` is where a session lives.
library;

import 'dart:math';

const _suffixAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
const _suffixLength = 4;

String newSessionId({DateTime? at, Random? random}) {
  final t = at ?? DateTime.now();
  final rng = random ?? Random.secure();
  String p(int v, int w) => v.toString().padLeft(w, '0');
  final id = StringBuffer()
    ..writeAll([
      p(t.year, 4),
      '-',
      p(t.month, 2),
      '-',
      p(t.day, 2),
      'T',
      p(t.hour, 2),
      '-',
      p(t.minute, 2),
      '-',
      p(t.second, 2),
      '-',
    ]);
  for (int i = 0; i < _suffixLength; i++) {
    id.writeCharCode(
      _suffixAlphabet.codeUnitAt(rng.nextInt(_suffixAlphabet.length)),
    );
  }
  return id.toString();
}
