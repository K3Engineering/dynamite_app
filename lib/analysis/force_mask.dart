import 'plate_series.dart';

// ---------------------------------------------------------------------------
// Boolean-mask morphology over a force window
//
// Event detection works on the RAW force: a window is turned into a boolean
// mask (e.g. "below the flight threshold"), and robustness lives in the time
// domain — short False gaps are bridged (closing), short True runs discarded
// (opening). A plate ring crossing a threshold only ever splits a run, and a
// bridge longer than any ring excursion (60 ms covers ~8 Hz rings; ring
// frequencies only move the requirement down as `1 / (2·f)` as they slow)
// rejoins it. This replaces threshold-crossing on a filtered signal, whose
// edges lag or smear and whose amplitude choice can never survive a big ring.
// ---------------------------------------------------------------------------

/// One maximal run of a mask, inclusive `[start, end]` in absolute sample
/// indices (a window's own index space).
typedef MaskRun = ({int start, int end});

extension MaskRunLength on MaskRun {
  int get length => end - start + 1;
}

/// The maximal runs of `holds(forceAt(i))` inside [w], with False gaps
/// shorter than [bridgeSamples] merged back in (closing) and True runs
/// shorter than [minSamples] dropped (opening). A run that reaches [w]'s
/// last sample is "open" — the event may still be running past the window;
/// callers treat it as in-progress, never as settled.
List<MaskRun> maskedRuns(
  PlateWindow w,
  bool Function(double) holds, {
  int bridgeSamples = 0,
  int minSamples = 1,
}) {
  final raw = <MaskRun>[];
  int? runStart;
  for (int i = w.start; i < w.end; i++) {
    if (holds(w.forceAt(i))) {
      runStart ??= i;
    } else if (runStart != null) {
      raw.add((start: runStart, end: i - 1));
      runStart = null;
    }
  }
  if (runStart != null) raw.add((start: runStart, end: w.end - 1));
  final runs = <MaskRun>[];
  for (final r in raw) {
    if (runs.isNotEmpty && r.start - runs.last.end - 1 < bridgeSamples) {
      runs[runs.length - 1] = (start: runs.last.start, end: r.end);
    } else {
      runs.add(r);
    }
  }
  return [
    for (final r in runs)
      if (r.length >= minSamples) r,
  ];
}

/// True when the run's end is "open": it reaches the window edge and the
/// mask still holds there, so the event may continue past the window.
bool runIsOpen(PlateWindow w, MaskRun run, bool Function(double) holds) =>
    run.end == w.end - 1 && holds(w.forceAt(w.end - 1));
