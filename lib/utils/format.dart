/// Shared display formatters and cross-referenced copy.
library;

/// ISO 8601 with an explicit zone designator: `...Z` for UTC, `±hh:mm` for
/// local times (which [DateTime.toIso8601String] leaves suffix-less). Frozen
/// into the session row as the CSV `recorded_at`.
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

/// "1,040" — comma-grouped integer, hand-rolled to avoid the intl dep.
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

/// "01:23" below an hour, "1:02:03" above; fixed-width so the label doesn't
/// jitter as digits tick.
String formatElapsedClock(Duration d) {
  final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
  final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// "2026-07-20" — ISO 8601, zero-padded; the app's one date voice.
String formatDate(DateTime dt) {
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

/// [formatDate] plus the 24h zero-padded wall-clock time (minute precision).
String formatTimestamp(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '${formatDate(dt)} $h:$min';
}

/// Display title for a session with an empty name. One shared string so the
/// list, detail, and delete-confirm copy can't drift.
const String untitledSessionName = 'Untitled session';

/// Coarse relative age for the Devices tab's "Last seen/connected" lines.
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

/// "512 B", "84 MB", "8.4 GB"; 1024-based, one decimal below 10.
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

/// Conservative recording runway, floored to a coarse bucket so the displayed
/// number is always a minimum ("≈ 11 h" means at least 11 h).
String formatRunway(Duration runway) {
  if (runway.inDays >= 2) return '≈ ${runway.inDays} d';
  if (runway.inHours >= 2) return '≈ ${runway.inHours} h';
  if (runway.inMinutes >= 15) return '≈ ${runway.inMinutes ~/ 5 * 5} min';
  return '< 15 min';
}
