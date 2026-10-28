import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';
import 'gait.dart';
import 'metric_eval.dart';
import 'metrics.dart';
import 'metrics_isometric.dart';
import 'metrics_single_leg.dart';
import 'metrics_sway.dart';
import 'plate_series.dart';
import 'segmentation_cmj.dart';
import 'segmentation_dj.dart';
import 'test_def.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// One descriptor per test family
//
// [TestFamilyOps] is the single place that knows how a family's stored reps are
// re-read, which metrics they carry, and how they annotate a graph. The runner,
// the summary table and the session reader all look it up through [opsFor];
// none of them switches on [TestFamily]. That is what makes "adding a test is
// adding data, not a screen" true at the call sites too, not just in [TestDef].
// ---------------------------------------------------------------------------

/// One evaluated rep of any family: its metric evaluation, the phase spans that
/// split its window (for persistence), and its graph annotation.
///
/// The window is [RepEvaluation.start]..[RepEvaluation.end] in whichever index
/// space produced it — the live source's while a run is in flight, the
/// recording's when re-read from a session.
@immutable
class EvaluatedRep {
  const new({
    required this.eval,
    this.spans = const [],
    this.overlays = const GraphOverlays(),
  });

  final RepEvaluation eval;

  /// Labeled phase spans covering the window, ascending and non-overlapping.
  /// Empty for a window-only capture.
  final List<PhaseSpan> spans;

  /// What this rep contributes to the graph: phase or window shading, a CoP
  /// ellipse, a gait line.
  final GraphOverlays overlays;

  int get number => eval.number;

  double? metric(String id) => eval.metric(id);

  /// This rep as persisted, shifted by [delta] samples (from the live source's
  /// index space into the recording slice's).
  TestRep toTestRep(int delta) => TestRep(
    label: eval.label,
    start: eval.start + delta,
    end: eval.end + delta,
    spans: [for (final s in spans) s.shifted(delta)],
  );
}

/// A computed trailing column of a rep table (mean, ratio): one value per
/// metric row, keyed by the metric's id.
@immutable
class RepTableTrailing {
  const new(this.header, this.valueFor);

  final String header;
  final double? Function(String metricId) valueFor;
}

/// A freeform row appended after the metric rows (the jump battery's EUR).
@immutable
class RepTableRow {
  const new({
    required this.label,
    required this.decimals,
    required this.values,
    this.unit = '',
  });

  final String label;
  final String unit;
  final int decimals;
  final List<double?> values;
}

/// Everything needed to draw a family's metric × rep table, as data: the
/// analysis core must not import widgets, so the table widget adapts this.
@immutable
class RepTableSpec {
  const new({
    required this.metrics,
    required this.reps,
    this.columnLabels,
    this.trailing = const [],
    this.extraRows = const [],
  });

  final List<MetricDef<dynamic>> metrics;

  /// One column per rep, in display order.
  final List<RepEvaluation> reps;

  /// Overrides the per-rep column headers ("Rep n (CMJ)", "Pass n"); the
  /// default is the rep's label, or "Rep n" when unlabeled.
  final List<String>? columnLabels;

  final List<RepTableTrailing> trailing;
  final List<RepTableRow> extraRows;
}

/// Why a stored test result can't be shown. The section fails as a whole
/// rather than dropping the unreadable reps: a table covering fewer reps than
/// its header claims is a lie. The session's raw graphs and CSV export stay
/// available either way.
class TestResultUnreadable implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a re-read needs beyond one stored rep.
@immutable
class FamilyReadContext {
  const new({
    required this.bodyWeightKgf,
    required this.def,
    required this.data,
  });

  final double bodyWeightKgf;

  /// The test definition: protocol facts (an isometric band) that a
  /// measurement doesn't carry.
  final TestDef def;

  final GraphDataSource data;
}

/// A family's behaviour: how one stored rep re-evaluates, and how its reps
/// become a table.
@immutable
class TestFamilyOps {
  const new({required this.evaluateRep, required this.table});

  /// Re-read one rep from a loaded recording. Implementations throw
  /// [TestResultUnreadable] when the stored spans don't describe a rep of
  /// this family.
  final EvaluatedRep Function(
    TestRep rep,
    PlateReader reader,
    FamilyReadContext ctx,
    int number,
  )
  evaluateRep;

  /// The family's metric × rep table.
  final RepTableSpec Function(List<EvaluatedRep> reps) table;
}

/// The family's descriptor — the one place a [TestFamily] is switched on.
TestFamilyOps opsFor(TestFamily family) => switch (family) {
  TestFamily.jump => _jumpOps,
  TestFamily.dropJump => _dropJumpOps,
  TestFamily.sway => _swayOps,
  TestFamily.isometric => _isometricOps,
  TestFamily.singleLeg => _singleLegOps,
  TestFamily.gait => _gaitOps,
};

/// Re-evaluate every stored rep of [result] against [data]. Throws
/// [TestResultUnreadable] when the recording or any rep can't be read; the
/// caller shows the failure instead of a table that silently covers fewer reps
/// than the header claims.
List<EvaluatedRep> evaluateTestResult(
  TestResult result,
  GraphDataSource data,
  TestDef def,
) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) {
    throw const TestResultUnreadable(
      'The session has no readable plate calibration.',
    );
  }
  final ops = opsFor(def.family);
  final ctx = FamilyReadContext(
    bodyWeightKgf: result.bodyWeightKgf,
    def: def,
    data: data,
  );
  return [
    for (int i = 0; i < result.reps.length; i++)
      if (_fits(result.reps[i], data))
        ops.evaluateRep(result.reps[i], reader, ctx, i + 1)
      else
        throw TestResultUnreadable(
          'Rep ${result.reps[i].start}–${result.reps[i].end} lies outside '
          'the recording (${data.oldestSample}–${data.totalSamples}).',
        ),
  ];
}

bool _fits(TestRep rep, GraphDataSource data) =>
    rep.start >= data.oldestSample && rep.end <= data.totalSamples;

/// Mean over the reps' values, per metric id.
RepTableTrailing _meanTrailing(List<RepEvaluation> evals) =>
    RepTableTrailing('Mean', (id) {
      final values = [for (final r in evals) ?r.metric(id)];
      if (values.isEmpty) return null;
      return values.reduce((a, b) => a + b) / values.length;
    });

/// `b / a` per metric id (null when either side is missing or `a` is zero).
RepTableTrailing _ratioTrailing(
  String header,
  RepEvaluation a,
  RepEvaluation b,
) => RepTableTrailing(header, (id) {
  final x = a.metric(id);
  final y = b.metric(id);
  if (x == null || y == null || x == 0) return null;
  return y / x;
});

/// The interpretable rep-pair ratio, for families whose two-rep tests have
/// one (Romberg's eyes-closed / eyes-open, an isometric A/B pair).
RepTableTrailing? _pairRatio(List<RepEvaluation> evals) => evals.length != 2
    ? null
    : _ratioTrailing(
        swayRatioHeader(evals[0].label, evals[1].label),
        evals[0],
        evals[1],
      );

// -- Jump battery --

final TestFamilyOps _jumpOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) {
    final phases = CmjPhases.tryFromSpans(rep, sampleRate: ctx.data.sampleRate);
    if (phases == null) {
      throw TestResultUnreadable('Rep $number has no jump phases.');
    }
    return buildCmjRep(
      PlateWindow.capture(reader, rep.start, rep.end),
      phases,
      CmjContext(bwKgf: ctx.bodyWeightKgf),
      number,
    );
  },
  table: (reps) => RepTableSpec(
    metrics: cmjMetrics,
    reps: [for (final r in reps) r.eval],
    columnLabels: [for (final r in reps) 'Rep ${r.number} (${r.eval.label})'],
    trailing: [
      _meanTrailing([for (final r in reps) r.eval]),
    ],
    extraRows: [
      if (eccentricUtilizationRatio(reps) case final eur?)
        RepTableRow(
          label: 'EUR (CMJ/SJ)',
          decimals: 2,
          values: [for (final _ in reps) null, eur],
        ),
    ],
  ),
);

// -- Drop jump --

final TestFamilyOps _dropJumpOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) {
    final phases = DjPhases.tryFromSpans(rep, sampleRate: ctx.data.sampleRate);
    if (phases == null) {
      throw TestResultUnreadable('Rep $number has no drop-jump phases.');
    }
    return buildDjRep(
      PlateWindow.capture(reader, rep.start, rep.end),
      phases,
      number,
    );
  },
  table: (reps) => RepTableSpec(
    metrics: djMetrics,
    reps: [for (final r in reps) r.eval],
    trailing: [
      _meanTrailing([for (final r in reps) r.eval]),
    ],
  ),
);

// -- Quiet stance (sway) --

final TestFamilyOps _swayOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) => evaluateSwayWindow(
    PlateWindow.capture(reader, rep.start, rep.end),
    rep.label ?? '',
    number,
  ),
  table: (reps) {
    final evals = [for (final r in reps) r.eval];
    return RepTableSpec(
      metrics: swayMetrics,
      reps: [for (final r in reps) r.eval],
      trailing: [?_pairRatio(evals)],
    );
  },
);

// -- Isometric holds --

final TestFamilyOps _isometricOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) {
    // The target band is protocol (the test definition), not measurement.
    final band = ctx.def.isoBand!;
    return evaluateIsoWindow(
      PlateWindow.capture(reader, rep.start, rep.end),
      IsoContext.forBw(
        ctx.bodyWeightKgf,
        band.centerFractionOfBw,
        band.halfWidthFraction,
      ),
      rep.label ?? '',
      number,
    );
  },
  table: (reps) {
    final evals = [for (final r in reps) r.eval];
    return RepTableSpec(
      metrics: isoMetrics,
      reps: [for (final r in reps) r.eval],
      // A ratio over two holds, a mean over more, bare values for one.
      trailing: [
        ?_pairRatio(evals),
        if (evals.length > 2) _meanTrailing(evals),
      ],
    );
  },
);

// -- Single-leg stance --

final TestFamilyOps _singleLegOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) => evaluateSlWindow(
    PlateWindow.capture(reader, rep.start, rep.end),
    rep.label ?? '',
    number,
  ),
  table: (reps) =>
      RepTableSpec(metrics: slMetrics, reps: [for (final r in reps) r.eval]),
);

// -- Gait passes --

final TestFamilyOps _gaitOps = TestFamilyOps(
  evaluateRep: (rep, reader, ctx, number) {
    final pass = evaluateGaitPass(
      reader,
      (start: rep.start, end: rep.end),
      number,
      GaitContext(bwKgf: ctx.bodyWeightKgf),
    );
    if (pass == null) {
      throw TestResultUnreadable('Rep $number is not a valid footstrike.');
    }
    return pass;
  },
  table: (reps) => RepTableSpec(
    metrics: gaitMetrics,
    reps: [for (final r in reps) r.eval],
    columnLabels: [for (final r in reps) 'Pass ${r.number}'],
    trailing: [
      _meanTrailing([for (final r in reps) r.eval]),
    ],
  ),
);
