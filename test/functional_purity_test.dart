import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The one functional core this package has (see segmented_cache_functional's
// header): a pure decision core importing nothing but `dart:core`/`dart:math`.
// The import check is an ALLOWLIST on purpose: a denylist is only as strong as
// the author's memory of what is impure, and the point of the core is to be
// provably free of side effects, not free of the ones we thought of. The
// identifier list below exists only because an allowlist of imports cannot
// reach the impure members that live in the two allowed libraries (DateTime,
// Stopwatch, Random, print).
//
// Everything here reads source TEXT. That is enough because nothing in Dart
// hides an import or a call from the compiler that would also hide it from
// this scan (no `part`, no code generation in lib/).

const _core = 'lib/widgets/graph/segmented_cache_functional.dart';

/// The core's raster shell, the one lib file allowed to import it.
const _shell = 'lib/widgets/graph/segmented_cache.dart';

/// URI prefixes a functional core may import. Deliberately excludes
/// `dart:io`, `dart:ui`, `dart:async` (Timer/Future scheduling), and every
/// package: a core that needs one of those is not a core.
const _allowedImportPrefixes = ['dart:core', 'dart:math'];

/// Impure members reachable through the allowed imports, so the allowlist
/// cannot catch them: DateTime/Stopwatch/print are `dart:core`, Random is
/// `dart:math`. Anything else impure needs an import the allowlist refuses.
final _bannedIdentifiers = [
  RegExp(r'\bDateTime\b'),
  RegExp(r'\bStopwatch\b'),
  RegExp(r'\bRandom\b'),
  RegExp(r'\bprint\s*\('),
];

final _importDirective = RegExp(r"^\s*(?:import|export)\s+'([^']+)'");

/// Every .dart file under lib/, as repo-relative slash paths.
List<String> _libFiles() => [
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart')) f.path.replaceAll('\\', '/'),
];

/// Import/export targets of [path].
List<String> _importsOf(String path) => [
  for (final line in File(path).readAsLinesSync())
    ?_importDirective.firstMatch(line)?.group(1),
];

/// [line] with its comment and its string-literal contents removed, so the
/// identifier scan sees code: the core names `DateTime` and friends in prose,
/// and a message string must not trip the net.
String _codeOf(String line) =>
    line.split('//').first.replaceAll(RegExp('''('[^']*'|"[^"]*")'''), "''");

void main() {
  test('the cache core imports only pure libraries and no impure members', () {
    expect(
      File(_core).existsSync(),
      isTrue,
      reason: 'the core moved; point this test at it rather than deleting it',
    );
    for (final target in _importsOf(_core)) {
      expect(
        _allowedImportPrefixes.any(target.startsWith),
        isTrue,
        reason:
            '$_core must not import "$target" '
            '(allowed: $_allowedImportPrefixes)',
      );
    }
    for (final line in File(_core).readAsLinesSync()) {
      final code = _codeOf(line);
      for (final banned in _bannedIdentifiers) {
        expect(
          banned.hasMatch(code),
          isFalse,
          reason:
              '$_core: "${line.trim()}" references a side-effecting '
              'identifier',
        );
      }
    }
  });

  test('the core is private to its shell', () {
    // The core is an implementation detail: it is deliberately NOT
    // re-exported, so its types never become package API. Nothing enforces
    // that in an app package (@internal only fires across packages, and
    // `part` would defeat the purity scan above), so this is the net: any
    // other lib file importing a core fails the build, and the fix is to
    // reach for the shell's public surface instead. Matching on the basename
    // is enough -- it is unique in lib/ -- and needs no path resolution.
    final offenders = [
      for (final file in _libFiles())
        if (file != _shell)
          for (final target in _importsOf(file))
            if (target.endsWith('/segmented_cache_functional.dart'))
              '$file imports "$target"',
    ];
    expect(
      offenders,
      isEmpty,
      reason: 'the core is private to $_shell:\n${offenders.join('\n')}',
    );
  });
}
