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

/// "Jul 20, 2026".
String formatDate(DateTime dt) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
}

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
