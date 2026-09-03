/// Recording write rate estimate: 4 channels x 4 bytes x the 1 kHz the
/// device boots at (a planning estimate, not the stream's parsed rate).
const int kRecordingBytesPerSecond = 16000;

/// What the platform storage probe found, rendered as the Sessions tab's
/// storage strip. Native platforms measure real disk numbers →
/// [StorageCapacity]. Browsers get [StorageEvictable]: their quantitative
/// estimate is unreliable enough to show nothing (see
/// `storage_probe_web.dart`), only the missing eviction guarantee is worth
/// a warning.
sealed class StorageState {
  const StorageState();
}

/// The web storage verdict: this origin's storage is best-effort, so the
/// browser may evict stored sessions under disk pressure. Persistent
/// storage (and unsupported/failed probes) report null instead — no
/// warning needed.
class StorageEvictable extends StorageState {
  const StorageEvictable();
}

/// The native storage verdict: how much the app is using and how much more
/// it can expect to write. [usedBytes] comes from the session store's byte
/// ledger (scan-seeded, delta-maintained); [availableBytes] is real free
/// space on the volume.
class StorageCapacity extends StorageState {
  const StorageCapacity({
    required this.usedBytes,
    required this.availableBytes,
  });

  final int usedBytes;
  final int availableBytes;

  /// Bar fill for the strip: used over used+available (the app's share of
  /// remaining space on the volume).
  double get usedFraction {
    final total = usedBytes + availableBytes;
    if (total <= 0) return 0;
    return (usedBytes / total).clamp(0.0, 1.0);
  }

  /// Conservative recording runway: what the user can expect to actually
  /// get, with high probability. The safety factor covers concurrent
  /// writers (other apps on the volume).
  Duration get recordingRunway {
    final seconds = (availableBytes * _safetyFactor / kRecordingBytesPerSecond)
        .floor();
    return Duration(seconds: seconds < 0 ? 0 : seconds);
  }

  static const double _safetyFactor = 0.9;
}

/// True when a browser user agent belongs to a family that may delete
/// stored sessions on its own schedule — the WebKit crowd: Safari (ITP
/// evicts script-written storage after 7 days without user interaction),
/// Bluefy, and every other iOS browser (all WKWebView shells with
/// WebKit-managed storage; their `CriOS`/`FxiOS` tokens carry neither
/// `Chrome/` nor `Firefox/`). Firefox is excluded — it only evicts under
/// disk pressure, LRU-ordered. Chromium forks (Edge, Opera, Samsung
/// Internet) keep the `Chrome/` token and share Chrome's storage behavior.
/// The check stays negative-match so unknown exotic browsers still warn: a
/// false positive costs one info banner, a false negative costs lost
/// sessions.
bool userAgentMayAutoDelete(String userAgent) =>
    !userAgent.contains('Chrome/') && !userAgent.contains('Firefox/');
