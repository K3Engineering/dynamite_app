import 'package:meta/meta.dart';

/// Persisted result of a guided test: the subject, the measured body weight,
/// and each rep's analysis window in the recording's sample-index space.
///
/// Reps are deliberately mold-neutral: a jump carries its phase splits as
/// [PhaseSpan]s (the jump family assigns the labels, see
/// `segmentation_cmj.dart`), a fixed-duration capture (quiet stance,
/// isometric hold) carries only its window. Metric values are NOT stored —
/// they are recomputed from the recording plus these bounds, so improving a
/// metric definition applies to old sessions too, and a stored number can
/// never drift from its recording.
@immutable
class TestResult {
  const TestResult({
    required this.testId,
    required this.person,
    required this.bodyWeightKgf,
    required this.reps,
  });

  /// [TestDef.id] of the test that produced this.
  final String testId;

  /// Free-text subject label; empty when none was given.
  final String person;

  /// Body weight measured during the stance phase, kgf.
  final double bodyWeightKgf;

  /// Valid reps, in capture order.
  final List<TestRep> reps;

  Map<String, dynamic> toJson() => {
    'testId': testId,
    'person': person,
    'bodyWeightKgf': bodyWeightKgf,
    'reps': [for (final r in reps) r.toJson()],
  };

  /// Strict parse: a missing or malformed field throws [FormatException].
  factory TestResult.fromJson(Map<String, dynamic> json) {
    final testId = json['testId'];
    if (testId is! String) {
      throw FormatException('testResult: bad testId: $testId');
    }
    final person = json['person'];
    if (person is! String) {
      throw FormatException('testResult: bad person: $person');
    }
    final bw = json['bodyWeightKgf'];
    if (bw is! num || !bw.toDouble().isFinite) {
      throw FormatException('testResult: bad bodyWeightKgf: $bw');
    }
    final reps = json['reps'];
    if (reps is! List) {
      throw FormatException('testResult: bad reps: $reps');
    }
    return TestResult(
      testId: testId,
      person: person,
      bodyWeightKgf: bw.toDouble(),
      reps: [
        for (final r in reps)
          TestRep.fromJson(
            r is Map
                ? Map<String, dynamic>.from(r)
                : throw const FormatException('testResult: bad rep'),
          ),
      ],
    );
  }
}

/// One valid rep: a captured window plus the phase labels that split it, in
/// the recording's sample-index space.
@immutable
class TestRep {
  const TestRep({
    this.label,
    required this.start,
    required this.end,
    required this.sampleRate,
    this.spans = const [],
  });

  /// The rep's classification within the test (jump style, "eyes open"),
  /// or null when the test has one rep kind.
  final String? label;

  /// Analysis window `[start, end)` in samples.
  final int start;
  final int end;
  final int sampleRate;

  /// Labeled phase spans covering parts of the window, ascending and
  /// non-overlapping. Empty for a window-only capture.
  final List<PhaseSpan> spans;

  Map<String, dynamic> toJson() => {
    if (label != null) 'label': label,
    'start': start,
    'end': end,
    'sampleRate': sampleRate,
    'spans': [for (final s in spans) s.toJson()],
  };

  /// Strict parse: bounds must be internally ordered, spans ascending and
  /// contained in the window; anything else is corruption.
  factory TestRep.fromJson(Map<String, dynamic> json) {
    int req(String key) {
      final v = json[key];
      if (v is! int) {
        throw FormatException('testRep: bad $key: $v');
      }
      return v;
    }

    final sampleRate = req('sampleRate');
    if (sampleRate <= 0) {
      throw FormatException('testRep: bad sampleRate: $sampleRate');
    }
    final start = req('start');
    final end = req('end');
    if (start >= end) {
      throw const FormatException('testRep: window bounds out of order');
    }
    final labelJson = json['label'];
    if (labelJson != null && labelJson is! String) {
      throw FormatException('testRep: bad label: $labelJson');
    }
    final spansJson = json['spans'];
    if (spansJson is! List) {
      throw FormatException('testRep: bad spans: $spansJson');
    }
    final spans = <PhaseSpan>[
      for (final s in spansJson)
        PhaseSpan.fromJson(
          s is Map
              ? Map<String, dynamic>.from(s)
              : throw const FormatException('testRep: bad span'),
        ),
    ];
    for (int i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (s.start < start ||
          s.end > end ||
          (i > 0 && s.start < spans[i - 1].end)) {
        throw const FormatException('testRep: span outside its window');
      }
    }
    return TestRep(
      label: labelJson as String?,
      start: start,
      end: end,
      sampleRate: sampleRate,
      spans: spans,
    );
  }
}

/// A named section of a rep's window, e.g. the eccentric phase of a jump.
/// `[start, end)` in the recording's sample-index space.
@immutable
class PhaseSpan {
  const PhaseSpan({
    required this.label,
    required this.start,
    required this.end,
  });

  final String label;
  final int start;
  final int end;

  /// This span shifted by [delta] samples (e.g. from the live source's index
  /// space into the recording slice's).
  PhaseSpan shifted(int delta) =>
      PhaseSpan(label: label, start: start + delta, end: end + delta);

  Map<String, dynamic> toJson() => {'label': label, 'start': start, 'end': end};

  factory PhaseSpan.fromJson(Map<String, dynamic> json) {
    final label = json['label'];
    if (label is! String || label.isEmpty) {
      throw FormatException('phaseSpan: bad label: $label');
    }
    final start = json['start'];
    final end = json['end'];
    if (start is! int || end is! int) {
      throw FormatException('phaseSpan: bad bounds: $start, $end');
    }
    if (start >= end) {
      throw const FormatException('phaseSpan: bounds out of order');
    }
    return PhaseSpan(label: label, start: start, end: end);
  }
}
