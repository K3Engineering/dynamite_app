/// Recording write rate estimate: 4 channels x 4 bytes x the 1 kHz the
/// device boots at (a planning estimate, not the stream's parsed rate).
const int kRecordingBytesPerSecond = 16000;

/// A platform's storage verdict for the Sessions tab's capacity strip: how
/// much the app is using, how much more it can expect to write, and whether
/// the platform guarantees the data survives (web best-effort storage can be
/// evicted under pressure; native app storage cannot).
///
/// Both producers take [usedBytes] from the session store's byte ledger
/// (scan-seeded, delta-maintained). [availableBytes] differs: on web it's
/// quota headroom from navigator.storage.estimate() — an optimistic ceiling,
/// since Chrome derives quota from total disk size, not free space (its
/// usage half is unusable: Chrome's OPFS accounting drifts and renders the
/// corrupted counter as ~4 GB, so the ledger replaces it); on native it's
/// real free space on the volume.
class StorageCapacity {
  const StorageCapacity({
    required this.usedBytes,
    required this.availableBytes,
    required this.isPersistent,
  });

  final int usedBytes;
  final int availableBytes;
  final bool isPersistent;

  /// Bar fill for the strip: used over used+available (the origin's quota on
  /// web, the app's share of remaining space on native). Clamped — the web
  /// quota estimate is fuzzed, so usage can transiently read above quota.
  double get usedFraction {
    final total = usedBytes + availableBytes;
    if (total <= 0) return 0;
    return (usedBytes / total).clamp(0.0, 1.0);
  }

  /// Conservative recording runway: what the user can expect to actually
  /// get, with high probability. The safety factor covers quota fuzzing on
  /// web and concurrent writers (a second browser tab, other apps on
  /// native).
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
