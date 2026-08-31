/// A session directory the store cannot load as a session: its journal's
/// header line failed strict parse (the unrecoverable content — name,
/// calibration, tares, ssnOrigin — lives there and nowhere else), its
/// directory name isn't a session id, or the header landed without a single
/// data frame. Never deleted or repaired by the store itself: the list
/// surfaces it with affordances (raw exports of whatever bytes exist, a
/// user-gesture delete) and that's the only way out.
class DamagedSession {
  const DamagedSession({
    required this.id,
    required this.hasData,
    required this.hasMeta,
    required this.reason,
  });

  /// The directory name (a session id when parseable); every export
  /// artifact is named from it, not from the unreadable session name.
  final String id;

  /// data.raw exists and has bytes — enables the raw-samples export
  /// (frame-positioned int32-LE counts for hand recovery).
  final bool hasData;

  /// The journal file exists and has bytes — enables the raw-metadata
  /// export (for eyeball recovery of calibration/tares).
  final bool hasMeta;

  /// Why the store flags it — display text for the list component, not
  /// state anything branches on.
  final String reason;
}
