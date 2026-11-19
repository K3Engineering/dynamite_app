import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../analysis/events.dart';
import '../analysis/gait.dart';
import '../analysis/metrics.dart';
import '../analysis/metrics_isometric.dart';
import '../analysis/metrics_single_leg.dart';
import '../analysis/metrics_sway.dart';
import '../analysis/plate_series.dart';
import '../analysis/segmentation_cmj.dart';
import '../analysis/segmentation_dj.dart';
import '../analysis/test_def.dart';
import '../analysis/test_family.dart';
import '../models/graph_overlays.dart';

// ---------------------------------------------------------------------------
// One state machine per mold
//
// The recording window is exactly one [MoldFlow]'s lifetime, and each mold
// owns the fields it needs ([RepCountFlow]'s rep start, [TimedCaptureFlow]'s
// window cursor, [FreePassFlow]'s scan pointer). No mold can leave another's
// state behind, because no other mold's state exists while it runs — the
// cross-mold reset discipline of a controller-side field set cannot be
// expressed here at all.
//
// A flow is a pure decision over its own state plus a [MoldTick]: it returns
// [MoldEvent]s and the controller owns every side effect (cues, repaints, the
// recorder). That keeps the arm counts and the branchiness in one small
// module, testable without a recorder.
// ---------------------------------------------------------------------------

/// Plate force below this is "empty" (tared to zero plus noise). kgf.
const double kEmptyPlateKgf = 2.0;

/// A rep that never produces a jump within this long is discarded.
const int kMaxJumpMs = 6000;

/// Recording keeps running this long after the last accepted rep (stabilization
/// data for the archive), then the run stops automatically.
const int kRecordTailSeconds = 3;

/// The arming window between reps, and the isometric band-entry sustain: 300
/// ms in both cases (a rep's dip can follow the quiet almost immediately, so
/// this is deliberately shorter than the 1 s body-weight window).
const int kShortWindowMs = 300;

/// One tick's observations: the plate as it stands now.
@immutable
class MoldTick {
  const new({
    required this.reader,
    required this.totalSamples,
    required this.oldestSample,
    required this.bwKgf,
    required this.sigmaKgf,
    required this.nextNumber,
  });

  final PlateReader reader;
  final int totalSamples;
  final int oldestSample;

  /// Body weight measured during the stance phase, kgf.
  final double bwKgf;

  /// Its noise floor, kgf (the jump onset band's width).
  final double sigmaKgf;

  /// The 1-based number the next accepted rep gets (the reps so far + 1).
  final int nextNumber;

  int get sampleRate => reader.sampleRate;

  /// Sample count for [ms] at this rate, at least one.
  int samplesFor(int ms) => math.max(1, ms * sampleRate ~/ 1000);

  /// The trailing `[total - ms, total)` window, clamped to retention.
  PlateWindow trailing(int ms) => window(totalSamples - samplesFor(ms));

  /// `[from, total)` captured, clamped to retention.
  PlateWindow window(int from) =>
      PlateWindow.capture(reader, math.max(from, oldestSample), totalSamples);
}

/// What a flow decided this tick. The controller turns these into cues, state
/// changes and recorder calls — the events are the whole interface.
sealed class MoldEvent {
  const new();
}

/// A rep completed and validated.
final class RepAccepted extends MoldEvent {
  const new(this.rep);

  final EvaluatedRep rep;
}

/// An attempt was rejected; [reason] is the coaching note shown to the athlete.
final class RepDiscarded extends MoldEvent {
  const new(this.reason);

  final String reason;
}

/// A rep's onset registered (the athlete started moving, the window opened).
final class RepStarted extends MoldEvent {
  const new();
}

/// A timed-capture window opened.
final class WindowStarted extends MoldEvent {
  const new(this.number);

  /// 1-based window number.
  final int number;
}

/// The isometric hold's force entered the target band.
final class BandEntered extends MoldEvent {
  const new();
}

/// The gait scan armed: the stance baseline is past, walking counts now.
final class GaitArmed extends MoldEvent {
  const new();
}

/// The run cannot continue; [message] is user-facing. The recording of
/// whatever was captured is still finalized and saved.
final class RunFailed extends MoldEvent {
  const new(this.message);

  final String message;
}

/// The mold captured everything it was asked for; stop the recording.
final class MoldCompleted extends MoldEvent {
  const new();
}

/// One mold's state machine, alive for exactly one recording.
sealed class MoldFlow {
  const new(this.test);

  final TestDef test;

  /// Advance by one tick.
  List<MoldEvent> tick(MoldTick t);

  /// The in-flight rep's preview annotation, when there is one. Cached from
  /// the tick's own segmentation, so a rebuild never re-segments the window.
  GraphOverlays? get previewOverlays => null;

  /// True when the next rep's onset will be detected (a stable stance, or a
  /// quiet empty plate). Drives the "stand still" vs "jump" prompt.
  bool get armed => false;

  /// The source's sample count at which an unchanged battery auto-stops the
  /// recording (the tail after the last rep), or null before it is full.
  int? get stopAfterSample => null;

  /// Which timed window is being captured, and how long it has left. Null
  /// outside a timed-capture flow.
  CaptureProgress? get captureProgress => null;

  /// The active isometric hold band in kgf, for the status strip's aim line.
  ({double low, double high, double center})? get bandKgfs => null;

  /// True while a rep is being segmented (rep-count flows only).
  bool get repInProgress => false;
}

/// Progress through a timed capture: which window, its length, how much is
/// left, and whether an isometric hold is still waiting for band entry.
@immutable
class CaptureProgress {
  const new({
    required this.number,
    required this.count,
    required this.label,
    required this.durationMs,
    required this.remainingMs,
    required this.awaitingBand,
  });

  final int number;
  final int count;
  final String label;
  final int durationMs;
  final int remainingMs;
  final bool awaitingBand;
}

/// The flow for [def] at the start of a recording.
MoldFlow flowFor(
  TestDef def, {
  required TestJumpStyle jumpStyle,
  required int totalSamples,
}) => switch (def.mold) {
  TestMold.repCount => RepCountFlow(def, jumpStyle: jumpStyle),
  TestMold.timedCapture => TimedCaptureFlow(def, startedAt: totalSamples),
  TestMold.freePass => FreePassFlow(def, startedAt: totalSamples),
};

// ---------------------------------------------------------------------------
// Rep count (jumps): N auto-segmented reps between armings
// ---------------------------------------------------------------------------

/// N reps, each segmented offline over the growing window `[repStart, now]`.
/// Between reps the flow waits for its arming condition, then for the onset
/// that starts the next rep.
class RepCountFlow extends MoldFlow {
  new(super.test, {required this.jumpStyle}) {
    // A usable body-weight baseline was just measured: stance-armed tests are
    // armed for rep 1. Unloaded arming (drop jump from a box) arms only once
    // the plate goes quiet-empty.
    _armed = test.arming == TestArming.stance;
  }

  final TestJumpStyle jumpStyle;

  /// End of the last accepted rep (bounds the onset walk-back so a new rep's
  /// onset can't retreat into the previous one's landing).
  int? _lastRepEnd;

  int? _repStart;
  bool _armed = false;
  int? _stopAfterCount;
  EvaluatedRep? _preview;

  /// True between an onset and the rep's acceptance: the athlete's movement is
  /// being segmented right now.
  @override
  bool get repInProgress => _repStart != null;

  @override
  bool get armed => _armed;

  @override
  int? get stopAfterSample => _stopAfterCount;

  @override
  GraphOverlays? get previewOverlays => _preview?.overlays;

  @override
  List<MoldEvent> tick(MoldTick t) =>
      _repStart == null ? _awaitOnset(t) : _advanceJump(t);

  /// Armed and waiting for the next rep. Stance-armed: a stable loaded stance
  /// arms, then the first sustained exit from the body-weight band starts a
  /// rep (down = countermovement, up = squat-jump push). Unloaded-armed: a
  /// quiet empty plate arms, then the first sustained load starts the rep (the
  /// drop-jump landing).
  List<MoldEvent> _awaitOnset(MoldTick t) {
    if (!_armed) {
      final ready = test.arming == TestArming.unloaded
          ? _plateUnloaded(t)
          : _stanceStable(t);
      if (!ready) return const [];
      _armed = true;
      // Newly armed is a prompt change, not a rep event: the controller
      // repaints on every tick anyway.
    }
    final onset = test.arming == TestArming.unloaded
        ? _unloadedOnset(t)
        : _stanceOnset(t);
    if (onset == null) return const [];
    _repStart = onset;
    _armed = false;
    return const [RepStarted()];
  }

  /// The unloaded arming's onset: the first sustained load over the drop-jump
  /// touchdown threshold (the landing).
  int? _unloadedOnset(MoldTick t) {
    final window = t.trailing(kShortWindowMs);
    final threshold = kDjParams.loadFraction * t.bwKgf;
    final contact = findSustainedAbove(
      window,
      window.start,
      window.end,
      threshold,
      t.samplesFor(kDjParams.sustainMs),
    );
    if (contact == null) return null;
    return _runStart(t, contact, (f) => f > threshold);
  }

  /// The stance arming's onset: the first sustained exit from the body-weight
  /// band.
  int? _stanceOnset(MoldTick t) {
    final window = t.trailing(kShortWindowMs);
    final (lower, upper) = onsetBandKgf(_jumpContext(t));
    final onset = findSustainedOutside(
      window,
      window.start,
      window.end,
      lower,
      upper,
      t.samplesFor(kJumpParams.onsetSustainMs),
    );
    if (onset == null) return null;
    return _runStart(t, onset, (f) => f < lower || f > upper);
  }

  /// The true start of the threshold run containing [detected], walked back
  /// from a bounded window (see [runStartBack]). Detection scans only the
  /// trailing 300 ms, so when a rep's movement began just before arming (a
  /// slow sink, a late tick), the in-window run start can be tens of ms late —
  /// and worse, batch-dependent. The walk never retreats into [_lastRepEnd].
  int _runStart(MoldTick t, int detected, bool Function(double) holds) {
    final oldest = math.max(t.oldestSample, _lastRepEnd ?? t.oldestSample);
    final w = PlateWindow.capture(
      t.reader,
      math.max(oldest, detected - 2 * t.sampleRate),
      detected + 1,
    );
    return runStartBack(w, detected, holds, oldest);
  }

  /// A quiet empty plate: the arming condition for unloaded-start tests
  /// (athlete back on the box between drop jumps).
  bool _plateUnloaded(MoldTick t) {
    if (t.totalSamples - t.oldestSample < t.samplesFor(kShortWindowMs)) {
      return false;
    }
    final window = t.trailing(kShortWindowMs);
    final baseline = estimateBaseline(window, window.start, window.end);
    return baseline != null && baseline.meanKgf.abs() < kEmptyPlateKgf;
  }

  /// A short loaded stance at body weight: the re-arm condition between reps.
  bool _stanceStable(MoldTick t) {
    if (t.totalSamples - t.oldestSample < t.samplesFor(kShortWindowMs)) {
      return false;
    }
    final window = t.trailing(kShortWindowMs);
    final baseline = estimateBaseline(window, window.start, window.end);
    if (baseline == null) return false;
    return (baseline.meanKgf - t.bwKgf).abs() < 0.05 * t.bwKgf &&
        baseline.sigmaKgf < 0.03 * t.bwKgf;
  }

  /// A rep is under way: segment `[repStart, now]` once and keep the result as
  /// the live preview, so a rebuild never repeats the work.
  List<MoldEvent> _advanceJump(MoldTick t) {
    final start = _repStart!;
    if (t.totalSamples - start > t.samplesFor(kMaxJumpMs)) {
      return _discard('No jump detected — try again.');
    }
    final window = PlateWindow.capture(t.reader, start, t.totalSamples);
    return test.family == TestFamily.dropJump
        ? _advanceDropJump(window, t)
        : _advanceCmj(window, t);
  }

  List<MoldEvent> _advanceDropJump(PlateWindow window, MoldTick t) {
    switch (segmentDj(window, t.bwKgf)) {
      case DjRep(:final phases):
        // A drop jump is always a rebound: no style gate applies.
        return _accept(buildDjRep(window, phases, t.nextNumber), phases.end, t);
      case DjRejected(:final reason):
        _preview = null;
        return switch (reason) {
          DjInvalidReason.noContact ||
          DjInvalidReason.noFlight ||
          DjInvalidReason.incomplete => const [],
          DjInvalidReason.noRebound => _discard(
            'No rebound detected — drop and jump straight back up.',
          ),
          DjInvalidReason.steppedOff => const [
            RunFailed('The athlete left the plate mid-jump.'),
          ],
        };
    }
  }

  List<MoldEvent> _advanceCmj(PlateWindow window, MoldTick t) {
    switch (segmentCmj(window, _jumpContext(t))) {
      case CmjRep(:final phases, :final jumpClass):
        final rep = buildCmjRep(
          window,
          phases,
          CmjContext(bwKgf: t.bwKgf),
          t.nextNumber,
        );
        _preview = rep;
        final rejection = _styleRejection(jumpClass);
        if (rejection != null) return _discard(rejection);
        return _accept(rep, phases.end, t);
      case CmjRejected(:final reason):
        _preview = null;
        return switch (reason) {
          CmjInvalidReason.noFlight || CmjInvalidReason.incomplete => const [],
          CmjInvalidReason.steppedOff => const [
            RunFailed('The athlete left the plate mid-jump.'),
          ],
        };
    }
  }

  /// Why the run's jump style rejects a rep of [jumpClass], or null when it
  /// counts. One exhaustive switch, so acceptance and its coaching note cannot
  /// disagree.
  String? _styleRejection(JumpClass jumpClass) => switch (jumpStyle) {
    TestJumpStyle.auto => null,
    TestJumpStyle.concentric when jumpClass == JumpClass.squat => null,
    TestJumpStyle.concentric =>
      'Only no-dip jumps count here — that one had a dip. Push straight up.',
    TestJumpStyle.eccentric when jumpClass == JumpClass.countermovement => null,
    TestJumpStyle.eccentric =>
      'Only dipped jumps count here — that one had no dip. '
          'Sink first, then jump.',
  };

  List<MoldEvent> _accept(EvaluatedRep rep, int repEnd, MoldTick t) {
    _preview = null;
    _repStart = null;
    _lastRepEnd = repEnd;
    if (rep.number >= (test.repCount ?? 1)) {
      // Battery full: the recording rides out the tail, then stops.
      _stopAfterCount = t.totalSamples + kRecordTailSeconds * t.sampleRate;
    }
    return [RepAccepted(rep)];
  }

  List<MoldEvent> _discard(String reason) {
    _preview = null;
    _repStart = null;
    return [RepDiscarded(reason)];
  }

  JumpContext _jumpContext(MoldTick t) =>
      JumpContext(bwKgf: t.bwKgf, sigmaKgf: t.sigmaKgf);
}

// ---------------------------------------------------------------------------
// Timed capture (sway / isometric / single leg): fixed-duration windows
// ---------------------------------------------------------------------------

/// Fixed-duration windows in sequence, back to back — no re-baseline between
/// them (the subject keeps standing through the transition).
class TimedCaptureFlow extends MoldFlow {
  new(super.test, {required int startedAt}) : _windowStart = startedAt;

  int _index = 0;

  /// Whether the flow has announced its first window. Window 0's start is the
  /// constructor's anchor, so it is announced on the first tick instead.
  bool _announced = false;

  /// Where the current window's rep starts. Window 0 starts at the recording's
  /// first sample (the constructor's anchor); every later window starts where
  /// its predecessor sealed, so windows are contiguous.
  int _windowStart;

  /// Where the force first entered the isometric band (sustained), or null
  /// while the athlete is still getting into it: the hold runs from here, not
  /// from the window's nominal start.
  int? _isoEntry;

  /// No band entry can start before this sample.
  int _isoScanFrom = 0;

  CaptureProgress? _progress;

  @override
  CaptureProgress? get captureProgress => _progress;

  @override
  ({double low, double high, double center})? get bandKgfs {
    final band = test.isoBand;
    if (band == null) return null;
    // Fractions of body weight: the status strip scales them, since the flow
    // has no body weight of its own between ticks.
    return (
      low: band.centerFractionOfBw - band.halfWidthFraction,
      high: band.centerFractionOfBw + band.halfWidthFraction,
      center: band.centerFractionOfBw,
    );
  }

  TestCaptureWindow get _def => test.windows[_index];

  /// Set once the last window seals; a completed flow ignores further ticks so
  /// it can never capture a rep nobody asked for.
  bool _completed = false;

  @override
  List<MoldEvent> tick(MoldTick t) {
    if (_completed) return const [];
    final events = <MoldEvent>[if (!_announced) _announce()];
    final target = t.samplesFor(_def.durationMs);
    final repStart = _repStartOf(t, events);
    if (repStart == null) return events;
    _updateProgress(t, repStart, target);
    if (t.totalSamples - repStart < target) return events;
    final window = PlateWindow.capture(t.reader, repStart, repStart + target);
    events.addAll(_seal(window, t));

    final next = _index + 1;
    if (next >= test.windows.length) {
      _completed = true;
      _progress = null;
      events.add(const MoldCompleted());
    } else {
      _index = next;
      _windowStart = repStart + target;
      _isoEntry = null;
      _isoScanFrom = 0;
      events.add(WindowStarted(next + 1));
    }
    return events;
  }

  /// Announce window 0 (its start is the constructor's anchor, not a tick's
  /// observation).
  WindowStarted _announce() {
    _announced = true;
    return const WindowStarted(1);
  }

  /// Where this window's rep starts, or null while it isn't known yet. Only
  /// the isometric family delays it (band entry); the others start at the
  /// window's opening sample.
  int? _repStartOf(MoldTick t, List<MoldEvent> events) {
    if (test.family != TestFamily.isometric) return _windowStart;
    final known = _isoEntry;
    if (known != null) return known;
    final entry = _findIsoEntry(t);
    if (entry == null) return null;
    events.add(const BandEntered());
    return entry;
  }

  void _updateProgress(MoldTick t, int repStart, int target) {
    _progress = CaptureProgress(
      number: _index + 1,
      count: test.windows.length,
      label: _def.label,
      durationMs: _def.durationMs,
      remainingMs: math.max(
        0,
        (target - (t.totalSamples - repStart)) * 1000 ~/ t.sampleRate,
      ),
      awaitingBand: test.family == TestFamily.isometric && _isoEntry == null,
    );
  }

  /// Close the window: evaluate its rep. Each family's window is one rep,
  /// except single leg, where the rep is the located lift inside it.
  List<MoldEvent> _seal(PlateWindow window, MoldTick t) {
    switch (test.family) {
      case TestFamily.sway:
        return [
          RepAccepted(evaluateSwayWindow(window, _def.label, t.nextNumber)),
        ];
      case TestFamily.isometric:
        return [
          RepAccepted(
            evaluateIsoWindow(
              window,
              IsoContext.forBw(
                t.bwKgf,
                test.isoBand!.centerFractionOfBw,
                test.isoBand!.halfWidthFraction,
              ),
              _def.label,
              t.nextNumber,
            ),
          ),
        ];
      case TestFamily.singleLeg:
        final interval = findSingleLegInterval(window, bwKgf: t.bwKgf);
        if (interval == null) {
          return const [
            RepDiscarded(
              'No single-leg lift detected — the window is discarded.',
            ),
          ];
        }
        return [
          RepAccepted(
            evaluateSlWindow(
              PlateWindow.capture(t.reader, interval.start, interval.end),
              interval.loadedLeft ? 'Left leg' : 'Right leg',
              t.nextNumber,
            ),
          ),
        ];
      // Timed windows belong to the three families above.
      case TestFamily.jump:
      case TestFamily.dropJump:
      case TestFamily.gait:
        throw StateError('${test.family.name} has no timed capture windows');
    }
  }

  /// Scan for the first sustained entry into the hold band, from the scan
  /// pointer. Only the tail is scanned, so a hold still being pushed into
  /// costs one sustain-length per tick rather than a rescan of the window.
  int? _findIsoEntry(MoldTick t) {
    final band = test.isoBand!;
    final low = t.bwKgf * (band.centerFractionOfBw - band.halfWidthFraction);
    final high = t.bwKgf * (band.centerFractionOfBw + band.halfWidthFraction);
    final sustain = t.samplesFor(kShortWindowMs);
    final from = math.max(_windowStart, _isoScanFrom);
    if (t.totalSamples - from < sustain) return null;
    final search = t.window(from);
    final entry = findSustainedInside(
      search,
      from,
      t.totalSamples,
      low,
      high,
      sustain,
    );
    if (entry == null) {
      // The earliest run the next tick could newly find starts just past the
      // last one this scan could have sampled in full.
      _isoScanFrom = math.max(from, t.totalSamples - sustain + 1);
      return null;
    }
    _isoEntry = entry;
    return entry;
  }
}

// ---------------------------------------------------------------------------
// Free pass (gait): a continuous stream segmented into passes
// ---------------------------------------------------------------------------

/// A continuous stream segmented into passes, stopped by the operator.
class FreePassFlow extends MoldFlow {
  new(super.test, {required int startedAt}) : _scanFrom = startedAt;

  /// Scan pointer into the source (absolute sample index).
  int _scanFrom;

  /// False until the plate has unloaded once after recording start: the stance
  /// baseline itself must not scan as a footstrike.
  bool _started = false;

  @override
  List<MoldEvent> tick(MoldTick t) {
    if (t.totalSamples <= _scanFrom) return const [];
    const params = kGaitParams;
    final threshold = params.loadFraction * t.bwKgf;
    final sustain = t.samplesFor(params.onsetSustainMs);
    final settle = t.samplesFor(params.settleMs);
    final window = t.window(_scanFrom);

    if (!_started) {
      // Skip the stance that measured body weight: wait for the first settled
      // unload, then start scanning for footstrikes.
      final off = findSustainedBelow(
        window,
        window.start,
        window.end,
        threshold,
        settle,
      );
      if (off == null) return const [];
      _scanFrom = off + settle;
      _started = true;
      return const [GaitArmed()];
    }

    final touchdown = findSustainedAbove(
      window,
      window.start,
      window.end,
      threshold,
      sustain,
    );
    if (touchdown == null) {
      // Idle plate: trim the scan window down to the armed tail so an idle
      // walk-by session doesn't rescan an ever-growing window every tick.
      _scanFrom = math.max(_scanFrom + 1, t.totalSamples - sustain);
      return const [];
    }
    final settleStart = findSustainedBelow(
      window,
      touchdown,
      window.end,
      threshold,
      settle,
    );
    if (settleStart == null) {
      // Contact longer than any footstrike: it's someone standing on the
      // plate. Drop the episode and wait for the unload before scanning on
      // (the same state as at recording start).
      if (t.totalSamples - touchdown > t.samplesFor(params.maxContactMs)) {
        _started = false;
        _scanFrom = touchdown;
        return const [
          RepDiscarded('Pass dropped: a touch or a stand, not a footstrike.'),
        ];
      }
      // Still in contact (or the tail hasn't arrived yet): next tick.
      return const [];
    }

    final episodeEnd = settleStart + settle;
    final episode = PlateWindow.capture(t.reader, touchdown, episodeEnd);
    _scanFrom = episodeEnd;
    final ctx = GaitContext(bwKgf: t.bwKgf);
    return switch (locateGaitContact(episode, ctx)) {
      GaitPass(:final touchdown, :final toeOff) => [
        RepAccepted(
          buildGaitPass(
            t.reader,
            GaitPass(touchdown, toeOff),
            t.nextNumber,
            ctx,
          ),
        ),
      ],
      GaitRejected(:final reason) => [
        RepDiscarded(switch (reason) {
          GaitInvalidReason.offPlateEdge =>
            'Pass dropped: the foot hit the plate edge.',
          GaitInvalidReason.contactLength =>
            'Pass dropped: a touch or a stand, not a footstrike.',
          GaitInvalidReason.underLoaded =>
            'Pass dropped: not enough weight on the plate.',
        }),
      ],
    };
  }
}
