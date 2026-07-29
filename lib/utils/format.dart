/// Shared display formatters for the session screens.
library;

/// "45s" below a minute, "3m 12s" below an hour, "1h 15m" above.
String formatDuration(Duration d) {
  if (d.inHours >= 1) {
    final min = d.inMinutes % 60;
    return '${d.inHours}h ${min}m';
  }
  if (d.inMinutes >= 1) {
    final sec = d.inSeconds % 60;
    return '${d.inMinutes}m ${sec}s';
  }
  return '${d.inSeconds}s';
}

/// "2026-07-20" — ISO 8601, zero-padded. Numeric Y-M-D is the app's one date
/// voice: culturally unambiguous (no D/M vs M/D confusion), fixed-width, and
/// locale-neutral, so a future localization never has to touch it (unlike
/// month names, which would need translation).
String formatDate(DateTime dt) {
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

/// "2026-07-20 14:05" — [formatDate] plus the 24h zero-padded wall-clock
/// time (minutes precision; seconds are noise at these call sites). Used
/// where the time of day distinguishes entries seen/saved within one day
/// (session cards, the cell-history picker).
String formatTimestamp(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '${formatDate(dt)} $h:$min';
}

/// Display title for a session with an empty name (reachable only via
/// out-of-band DB edits — rename refuses empty input and auto-names are
/// never empty). One shared string so the list, detail and delete-confirm
/// copy can't drift.
const String untitledSessionName = 'Untitled session';

/// Coarse relative age for the Devices tab's "Last seen/connected" lines:
/// "just now" below 5 s, then a widening ">5 s / >15 s / >30 s / >1 m / …"
/// ladder capped at ">1 hour ago". The coarse buckets keep the displayed age
/// stable for seconds or minutes at a time — a live-ticking count-up would
/// be distracting for no information gain.
String formatRelativeAge(Duration age) {
  final s = age.inSeconds;
  if (s < 5) return 'just now';
  if (s < 15) return '>5 seconds ago';
  if (s < 30) return '>15 seconds ago';
  if (s < 60) return '>30 seconds ago';
  final m = age.inMinutes;
  if (m < 5) return '>1 minute ago';
  if (m < 15) return '>5 minutes ago';
  if (m < 30) return '>15 minutes ago';
  if (m < 60) return '>30 minutes ago';
  return '>1 hour ago';
}
