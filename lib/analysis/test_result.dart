import 'package:meta/meta.dart';

import 'segmentation_cmj.dart';

/// Persisted result of a guided test: the subject, the measured body weight,
/// and each valid rep's phase boundaries in the recording's sample-index space.
///
/// Metric values are deliberately NOT stored. They are recomputed from the
/// recording plus these boundaries, so improving a metric definition applies to
/// old sessions too, and a stored number can never drift from its recording.
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
  final List<CmjPhases> reps;

  Map<String, dynamic> toJson() => {
    'testId': testId,
    'person': person,
    'bodyWeightKgf': bodyWeightKgf,
    'reps': [for (final p in reps) _phasesToJson(p)],
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
          _phasesFromJson(
            r is Map
                ? Map<String, dynamic>.from(r)
                : throw const FormatException('testResult: bad rep'),
          ),
      ],
    );
  }
}

Map<String, dynamic> _phasesToJson(CmjPhases p) => {
  'onset': p.onset,
  'bwCross': p.bwCross,
  'takeoff': p.takeoff,
  'landing': p.landing,
  'end': p.end,
  'sampleRate': p.sampleRate,
};

CmjPhases _phasesFromJson(Map<String, dynamic> json) {
  int req(String key) {
    final v = json[key];
    if (v is! int) {
      throw FormatException('testResult: bad $key: $v');
    }
    return v;
  }

  final sampleRate = req('sampleRate');
  if (sampleRate <= 0) {
    throw FormatException('testResult: bad sampleRate: $sampleRate');
  }
  final onset = req('onset');
  final bwCross = req('bwCross');
  final takeoff = req('takeoff');
  final landing = req('landing');
  final end = req('end');
  // A stored rep must be internally ordered; anything else is corruption.
  if (!(onset < bwCross &&
      bwCross < takeoff &&
      takeoff < landing &&
      landing < end)) {
    throw const FormatException('testResult: rep bounds out of order');
  }
  return CmjPhases(
    onset: onset,
    bwCross: bwCross,
    takeoff: takeoff,
    landing: landing,
    end: end,
    sampleRate: sampleRate,
  );
}
