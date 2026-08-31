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

/// The local wall-clock instant encoded in [id] — the session's createdAt
/// (sort instant and display timestamp). Strict: anything not exactly the
/// [newSessionId] format throws [FormatException] (the caller's verdict
/// that a foreign directory is squatting in the sessions root).
DateTime sessionIdCreatedAt(String id) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-[a-z0-9]{4}$',
  ).firstMatch(id);
  if (match == null) throw FormatException('malformed session id: $id');
  return DateTime(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}
