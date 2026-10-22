// Mutation testing, the light version: a catalog of one-edit mutants
// (needle -> replacement) against lib/, each run in place against the
// targeted graph-cache test files. A mutant is
//   * KILLED   -- the tests fail (good: the nets work);
//   * SURVIVED -- the tests pass (bad: a PROVEN hole in the nets; fix the
//                 tests, not the code);
//   * ROTTED   -- the needle no longer matches (the code moved; re-anchor
//                 the mutant).
// Historical disasters belong here one row each (the first three entries
// are real bugs from this repo, with their repro tests).
//
// Nothing prod-side changes, ever: mutants are applied to the file and
// restored from an in-memory copy in a finally block; the runner refuses
// to touch a dirty target file. Not wired into per-PR CI (minutes per
// run) -- run manually on verification-net or planner changes:
//   dart run tool/run_mutants.dart            # whole catalog
//   dart run tool/run_mutants.dart <name>     # one mutant
import 'dart:convert';
import 'dart:io';

class Mutant {
  const Mutant({
    required this.name,
    required this.file,
    required this.needle,
    required this.replacement,
    required this.killedBy,
    this.survive = false,
  });

  final String name;
  final String file;

  /// Exact current source; absence marks the mutant ROTTED.
  final String needle;
  final String replacement;

  /// The net expected to kill it (documentation, not enforcement).
  final String killedBy;

  /// Whether surviving is the CORRECT outcome -- for mutants that disable a
  /// debug-only guard, where the nets are supposed to catch the bug on their
  /// own. A `survive` mutant that is killed means a net started depending on
  /// the guard it is meant to be independent of.
  final bool survive;
}

const functional = 'lib/widgets/graph/segmented_cache_functional.dart';

const mutants = <Mutant>[
  Mutant(
    name: 'refresh-horizon-clamp-removed',
    file: functional,
    needle:
        '  end: math.min(p.end, math.min(env.covEnd, env.config'
        '.bakeableSamples)),',
    replacement: '  end: math.min(p.end, env.covEnd),',
    killedBy:
        '_clampPlan callers: fold-window unit tests, sim probe, model check '
        '(historical bug: refresh swallowing a right neighbor past a receded '
        'horizon)',
  ),
  Mutant(
    name: 'refresh-window-clamp-removed',
    file: functional,
    needle: '  start: math.max(p.start, env.covStart),',
    replacement: '  start: p.start,',
    killedBy:
        'fold-window unit tests, sim probe, model check '
        '(historical burn: re-bake of a view-straddling tile)',
  ),
  Mutant(
    name: 'gap-absorb-fold-clamp-removed',
    file: functional,
    needle:
        '''  // An absorbed neighbor may straddle the left view edge; the fold-window
  // invariant caps the bake at the window, dropping the neighbor's
  // out-of-fold fringe to an out-of-view gap.
  start = math.max(start, env.covStart);
''',
    replacement: '',
    killedBy:
        'fold window unit tests, sim probe, model check '
        '(historical burn: gap-bake left-absorb)',
  ),
  Mutant(
    name: 'plan-bakes-choke-point-assert-removed',
    file: functional,
    // Expected SURVIVED, and that is the correct verdict: the assert is a
    // debug-only backstop, so disabling it changes no release behaviour. The
    // nets are the sim and the model check, which re-derive the invariant
    // from first principles; this row proves they do not lean on the assert.
    survive: true,
    needle: '''  assert(
    job.start >= env.covStart &&
''',
    replacement: '''  assert(
    true &&
''',
    killedBy:
        'expected survivor: the test-side checks stand alone. If this ever '
        'reads KILLED, a net has started depending on the assert',
  ),
  Mutant(
    name: 'coverage-window-floor-ceil-swap',
    file: functional,
    needle: '''    covStart: c.viewStart.floor(),
    covEnd: viewEnd.ceil(),
''',
    replacement: '''    covStart: c.viewStart.ceil(),
    covEnd: viewEnd.floor(),
''',
    killedBy: 'geometry unit tests, model check',
  ),
  Mutant(
    name: 'absorb-limit-bloat',
    file: functional,
    needle: '(end - work[from - 1].start) * env.pps <= kSegmentTargetPx) {',
    replacement:
        '(end - work[from - 1].start) * env.pps <= 16 * kSegmentTargetPx) {',
    killedBy: 'geometry unit tests (over-wide merges shift bake ranges)',
  ),
  Mutant(
    name: 'drift-threshold-bloat',
    file: functional,
    needle: 'const double kMaxSegmentDrift = 0.08;',
    replacement: 'const double kMaxSegmentDrift = 0.5;',
    killedBy: 'rolling drift refresh unit tests',
  ),
  Mutant(
    name: 'destructive-suppress-removed',
    file: functional,
    needle:
        '  if (!_keyEq(s.destructiveKey, state.destructiveKey)) return '
        'false;',
    replacement:
        '  if (_keyEq(s.destructiveKey, state.destructiveKey)) return '
        'false;',
    killedBy:
        'blit-geometry unit tests: inverting the test suppresses the '
        'segments whose keys match, which only the blit list can observe',
  ),
  Mutant(
    name: 'blit-y-scale-doubled',
    file: functional,
    needle: '    final double ys = _blitYScale(s, c);',
    replacement: '    final double ys = _blitYScale(s, c) * 2;',
    killedBy: 'blit-geometry unit tests (dy/dh stretch)',
  ),
  Mutant(
    name: 'blit-x-offset-shifted',
    file: functional,
    needle: '      dx: x1 - s.hPad * xs,',
    replacement: '      dx: x1 + 7 - s.hPad * xs,',
    killedBy: 'blit-geometry unit tests (dx placement)',
  ),
  Mutant(
    name: 'gap-x-offset-shifted',
    file: functional,
    needle: '        x: (gs - c.viewStart) * env.pps,',
    replacement: '        x: (gs - c.viewStart) * env.pps + 5,',
    killedBy: 'blit-geometry unit tests (gap placement)',
  ),
  Mutant(
    name: 'suppression-cap-disabled',
    file: functional,
    needle: 'const double kMaxBlitLineFraction = 0.25;',
    replacement: 'const double kMaxBlitLineFraction = 100.0;',
    killedBy:
        'vertical-stretch suppression unit tests (blank-then-refill: a '
        'stretched segment must leave the blit list)',
  ),
];

const testTargets = [
  'test/segmented_graph_cache_test.dart',
  'test/graph_cache_sim_test.dart',
  'test/graph_cache_model_check_test.dart',
];

enum Verdict {
  killed,

  survived,

  /// The mutant is not valid Dart or fails to compile. A nonzero test exit
  /// in that case says nothing about the nets, so it must not be counted as
  /// a kill -- this verdict is why the runner analyzes first.
  invalid,

  /// The needle no longer matches: the code moved; re-anchor the mutant.
  rotted,
}

Future<Verdict> runMutant(Mutant m, String flutter) async {
  final file = File(m.file);
  final original = await file.readAsString();
  if (!original.contains(m.needle)) return Verdict.rotted;
  try {
    await file.writeAsString(original.replaceFirst(m.needle, m.replacement));
    // A mutant that does not compile exits nonzero from `flutter test` too.
    // Counting that as KILLED would credit the nets for a syntax error, so
    // analyze the mutated file first and refuse to judge it.
    final analysis = await Process.run(
      flutter,
      ['analyze', m.file],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (analysis.exitCode != 0) return Verdict.invalid;
    final result = await Process.run(
      flutter,
      ['test', ...testTargets],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return result.exitCode == 0 ? Verdict.survived : Verdict.killed;
  } finally {
    await file.writeAsString(original);
  }
}

Future<void> main(List<String> args) async {
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final selected = args.isEmpty
      ? mutants
      : mutants.where((m) => m.name == args.first).toList();
  if (selected.isEmpty) {
    stderr.writeln('no mutant named ${args.first}');
    exitCode = 2;
    return;
  }
  // Fail loudly instead of clobbering uncommitted work: the restore
  // writes back the ORIGINAL file content.
  for (final m in selected) {
    final dirty = await Process.run('git', [
      'status',
      '--porcelain',
      '--',
      m.file,
    ]);
    if ((dirty.stdout as String).trim().isNotEmpty) {
      stderr.writeln('${m.file} has uncommitted changes; refusing to run.');
      exitCode = 2;
      return;
    }
  }

  var failures = 0;
  final sw = Stopwatch()..start();
  for (final m in selected) {
    final verdict = await runMutant(m, flutter);
    final tag = switch (verdict) {
      Verdict.killed => 'KILLED  ',
      Verdict.survived => 'SURVIVED',
      Verdict.invalid => 'INVALID ',
      Verdict.rotted => 'ROTTED  ',
    };
    stdout.writeln('$tag  ${m.name}   (net: ${m.killedBy})');
    // A mutant flagged `survive` expects SURVIVED; anything else (rotted,
    // invalid, or unexpectedly killed) is a problem in its own right.
    final ok = m.survive
        ? verdict == Verdict.survived
        : verdict == Verdict.killed;
    if (!ok) failures++;
  }
  stdout.writeln(
    '${selected.length - failures}/${selected.length} as expected '
    '(${sw.elapsed})',
  );
  if (failures > 0) exitCode = 1;
}
