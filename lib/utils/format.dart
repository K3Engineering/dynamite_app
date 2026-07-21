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
