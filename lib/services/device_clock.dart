/// Syncs the PC clock to the device's sample oscillator so the live graph
/// can place its edge where the DEVICE is in time, not where the newest
/// confirmed packet landed.
///
/// The device sends 16-bit-counter-stamped batches; the counter gives every
/// delivery an exact device-time position, so per-packet arrival jitter
/// (packet-atomic delivery at 18.75 ms connection events, app scheduling) is
/// zero-mean noise around a noiseless device axis. The clock therefore fits
/// a line through recent (arrival time, sample index) deliveries
/// (least-squares slope = the device's true rate in PC-clock units) and
/// EXTRAPOLATES from it -- the jitter cancels in the fit instead of being
/// re-anchored per packet, which is what made a naive "newest sample plus
/// elapsed" edge rewind at multi-Hz on this link.
///
/// Crystal skew (tens of ppm on cheap BLE crystals) is absorbed by the
/// slope, so the projection stays glued to the device indefinitely; a
/// fixed-rate glide would drift by the skew times stream age.
///
/// Data path: [DataHub.commitBatch] calls [observe]; the graph painters read
/// [projectedEndAt] per frame. Both directions use the class's one
/// (monotonic, injectable) clock, so wall-clock slew never mixes in.
class DeviceClock {
  new({Duration Function()? now}) : _now = now ?? (() => _clock.elapsed);

  /// Monotonic epoch for the fit (site-managed time invites NTP-slew
  /// artifacts); injectable for tests. Mirrors `AdcPacketDecoder`'s clock.
  static final Stopwatch _clock = Stopwatch()..start();
  final Duration Function() _now;

  /// Recent deliveries `(arrival ms, sample index)`. Sized for ~5 s of ~50 Hz
  /// delivery: long enough that the fit's phase error sits below a graph
  /// pixel, short enough to forget a transient quickly. Fits are recomputed
  /// per read (O(capacity)), so the clock's only state is this ring.
  final List<({double t, double x})> _obs = [];
  static const int _capacity = 256;

  /// A delivery gap past this invalidates older observations: at >10 skipped
  /// connection events the PC/device sample-index relation may have shifted
  /// (monitoring pause discards device samples without advancing the hub
  /// timeline; a dead link just stopped delivering), so the refit starts
  /// from the fresh side of the gap.
  static const double _maxGapMs = 250;

  /// Shortest observation span trusted for a slope fit; shorter spans glide
  /// at the nominal rate (stream startup, the first second after a pause).
  static const double _minFitSpanMs = 1000;

  /// Note one confirmed delivery of [sampleIndex] samples (the hub's
  /// `totalSamples` at batch commit). Index, not arrival count: injected
  /// dropouts keep the index on the device's own axis across packet loss.
  void observe(int sampleIndex) {
    final double t = _now().inMicroseconds / 1e3;
    // Clear BEFORE appending so the fresh observation survives the reset.
    if (_obs.isNotEmpty && t - _obs.last.t > _maxGapMs) _obs.clear();
    _obs.add((t: t, x: sampleIndex.toDouble()));
    if (_obs.length > _capacity) _obs.removeRange(0, _obs.length - _capacity);
  }

  void clear() => _obs.clear();

  /// Estimated sample index the device is generating right now; null before
  /// the first delivery of a stream. Runs AHEAD of the sink's `totalSamples`
  /// by the delivery latency (samples exist on the device before a packet
  /// confirms them), which is where the graph's blank lead budget lives.
  double? projectedEndAt(int nominalRateHz) {
    if (_obs.isEmpty) return null;
    final double t = _now().inMicroseconds / 1e3;
    final last = _obs.last;
    if (last.t - _obs.first.t < _minFitSpanMs) {
      return last.x + (t - last.t) * nominalRateHz / 1000;
    }
    // Least-squares line through the ring, extrapolated from its centroid;
    // centering keeps the sums small (ms and sample counts are both ~1e7+).
    double tSum = 0, xSum = 0;
    for (final o in _obs) {
      tSum += o.t;
      xSum += o.x;
    }
    final double tBar = tSum / _obs.length;
    final double xBar = xSum / _obs.length;
    double varT = 0, covTX = 0;
    for (final o in _obs) {
      final double dt = o.t - tBar;
      varT += dt * dt;
      covTX += dt * (o.x - xBar);
    }
    // Slope in samples/ms; span >= _minFitSpanMs guarantees varT > 0.
    return xBar + covTX / varT * (t - tBar);
  }
}
