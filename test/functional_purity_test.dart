import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The *_functional.dart convention (see segmented_cache_functional.dart's
// header): a functional file is a pure decision core, importing nothing but
// `dart:core`/`dart:math` (plus its own siblings). The import check is an
// ALLOWLIST on purpose: a denylist is only as strong as the author's memory of
// what is impure, and the point of the core is to be provably free of side
// effects, not free of the ones we thought of. The identifier list below
// exists only because an allowlist of imports cannot reach the impure members
// that live in the two allowed libraries (DateTime, Stopwatch, Random, print).
//
// Everything here reads source TEXT. That is enough because nothing in Dart
// hides an import or a call from the compiler that would also hide it from
// this scan (no `part`, no code generation in lib/).

/// URI prefixes a functional core may import. Deliberately excludes
/// `dart:io`, `dart:ui`, `dart:async` (Timer/Future scheduling), every
/// package, and every non-functional lib file: a core that needs one of those
/// is not a core.
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

/// Basename of a functional core file.
final _functionalFile = RegExp(r'_functional\.dart$');

/// The shell that owns [core]: `x_functional.dart` next to `x.dart`, derived
/// rather than configured so a new core costs no edit here.
String _shellOf(String corePath) =>
    corePath.replaceFirst(_functionalFile, '.dart');

/// Import targets of [file].
List<String> _importsOf(File file) => [
  for (final line in file.readAsLinesSync())
    ?_importDirective.firstMatch(line)?.group(1),
];

/// [line] with its comment and its string-literal contents removed, so the
/// identifier scan sees code: the core names `DateTime` and friends in prose,
/// and a message string must not trip the net.
String _codeOf(String line) =>
    line.split('//').first.replaceAll(RegExp('''('[^']*'|"[^"]*")'''), "''");

void main() {
  test('*_functional.dart files are pure', () {
    final cores = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => _functionalFile.hasMatch(f.path))
        .toList();
    expect(
      cores,
      isNotEmpty,
      reason: 'the convention exists; if this is empty the test guards nothing',
    );
    for (final core in cores) {
      for (final target in _importsOf(core)) {
        // A core may import its siblings (a second core it shares value types
        // with); those are held to this same rule by the loop.
        final sibling = target.startsWith('.');
        expect(
          sibling || _allowedImportPrefixes.any(target.startsWith),
          isTrue,
          reason:
              '${core.path}: functional cores must not import "$target" '
              '(allowed: $_allowedImportPrefixes, or a sibling core)',
        );
      }
      for (final line in core.readAsLinesSync()) {
        final code = _codeOf(line);
        for (final banned in _bannedIdentifiers) {
          expect(
            banned.hasMatch(code),
            isFalse,
            reason:
                '${core.path}: "${line.trim()}" references a side-effecting '
                'identifier',
          );
        }
      }
      // The next test derives the shell from this filename, so fail here if
      // the convention is broken rather than silently passing.
      expect(
        File(_shellOf(core.path.replaceAll('\\', '/'))).existsSync(),
        isTrue,
        reason: '${core.path} has no sibling shell to own it',
      );
    }
  });

  test('a functional core is private to its shell', () {
    // The core is an implementation detail: it is deliberately NOT
    // re-exported, so its types never become package API. Nothing enforces
    // that in an app package (@internal only fires across packages, and
    // `part` would defeat the purity scan above), so this is the net: any
    // lib file other than the shell importing a core fails the build, and the
    // fix is to reach for the shell's public surface instead.
    final offenders = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final normalized = file.path.replaceAll('\\', '/');
      for (final target in _importsOf(file)) {
        if (!_functionalFile.hasMatch(target)) continue;
        // The shell is the core's own sibling (`x.dart` next to
        // `x_functional.dart`), resolved from the target so a core imported
        // by any other file is an offender no matter where it lives.
        if (normalized == _shellOf(_resolve(normalized, target))) continue;
        offenders.add('$normalized imports "$target"');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'functional cores are private to their shell:\n'
          '${offenders.join('\n')}',
    );
  });
}

/// [target] resolved against the directory holding [importer], as a
/// repo-relative slash path so `.`/`..` segments compare equal by value.
String _resolve(String importer, String target) {
  final parts = [...importer.split('/')..removeLast(), ...target.split('/')];
  final out = <String>[];
  for (final part in parts) {
    if (part == '.' || part.isEmpty) continue;
    if (part == '..') {
      out.removeLast();
    } else {
      out.add(part);
    }
  }
  return out.join('/');
}
