/// Shared display formatters for the session screens.
library;

/// Menu label of the damaged-data export, the one source so the menu item,
/// the save-as dialog title, and every cross-reference in copy can't drift.
const String salvageExportLabel = 'Export full raw data (damaged)';

/// "1,040" — comma-grouped integer. Hand-rolled on purpose: the intl
/// package is a heavier dep than one separator loop justifies.
String formatThousands(int n) {
  final digits = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

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
/// time (minutes precision; seconds are noise at these call sites).
String formatTimestamp(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '${formatDate(dt)} $h:$min';
}

/// ISO 8601 with an explicit zone designator: `...Z` for UTC, the wall clock
/// with its `±hh:mm` offset for local times. [DateTime.toIso8601String]
/// leaves local times suffix-less (ambiguous against UTC); [timeZoneOffset]
/// — the zone offset the OS tz database assigns to this instant, DST included
/// — supplies the suffix. Frozen into the session row at recording start as
/// the dynamite-csv `recorded_at` (csv-format-v1C.md).
String iso8601WithOffset(DateTime value) {
  if (value.isUtc) return value.toIso8601String();
  final offset = value.timeZoneOffset;
  if (offset.inSeconds % 60 != 0) {
    throw StateError(
      'unrepresentable zone offset $offset for $value (±hh:mm only)',
    );
  }
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '-' : '+';
  return '${value.toIso8601String()}$sign'
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';
}

/// Display title for a session with an empty name (reachable only via
/// out-of-band DB edits — rename refuses empty input and auto-names are
/// never empty). One shared string so the list, detail and delete-confirm
/// copy can't drift.
const String untitledSessionName = 'Untitled session';

/// Coarse relative age for the Devices tab's "Last seen/connected" lines.
/// The coarse buckets keep the displayed age stable for seconds or minutes
/// at a time — a live-ticking count-up would be distracting for no
/// information gain.
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

/// "512 B", "84 MB", "8.4 GB" — 1024-based, one decimal below 10 units and
/// none above: three significant digits are plenty for capacity display,
/// and the web numbers behind this are fuzzed estimates anyway.
String formatBytes(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  final rounded = value < 10
      ? value.toStringAsFixed(1)
      : value.toStringAsFixed(0);
  return '$rounded ${units[unit]}';
}

/// Conservative recording runway, floored to a coarse bucket so the
/// displayed number is always a minimum the user can expect ("≈ 11 h" means
/// at least 11 h): whole days at 2+, whole hours at 2+, 5-minute steps
/// below that, and a bare "< 15 min" at the floor.
String formatRunway(Duration runway) {
  if (runway.inDays >= 2) return '≈ ${runway.inDays} d';
  if (runway.inHours >= 2) return '≈ ${runway.inHours} h';
  if (runway.inMinutes >= 15) return '≈ ${runway.inMinutes ~/ 5 * 5} min';
  return '< 15 min';
}
