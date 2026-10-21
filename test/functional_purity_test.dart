import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The *_functional.dart convention (see segmented_cache_functional.dart's
// header): a functional file is a pure decision core

/// Import/export prefixes banned in functional files.
const _bannedImportPrefixes = [
  'dart:ui',
  'package:flutter/',
  'package:material_ui/',
];

/// Side-effecting identifiers matched in comment-stripped code (they need
/// no import: DateTime is dart:core, Random dart:math-adjacent).
final _bannedIdentifiers = [
  RegExp(r'\bDateTime\b'),
  RegExp(r'\bRandom\s*\('),
  RegExp(r'\bSchedulerBinding\b'),
];

final _importDirective = RegExp(r"^\s*(?:import|export)\s+'([^']+)'");

/// The one lib file allowed to import a functional core: its raster shell.
const _shellOfFunctionalCore = 'lib/widgets/graph/segmented_cache.dart';

/// Basename of a functional core file.
final _functionalFile = RegExp(r'_functional\.dart$');

void main() {
  test('*_functional.dart files are pure', () {
    final lib = Directory('lib');
    final functionalFiles = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('_functional.dart'))
        .toList();
    expect(
      functionalFiles,
      isNotEmpty,
      reason:
          'the convention exists; if this is empty the test guards '
          'nothing',
    );
    for (final file in functionalFiles) {
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        final directive = _importDirective.firstMatch(line);
        if (directive != null) {
          final target = directive.group(1)!;
          for (final prefix in _bannedImportPrefixes) {
            expect(
              target.startsWith(prefix),
              isFalse,
              reason:
                  '${file.path}: functional files must not import '
                  '"$target"',
            );
          }
        }
        // Comments may name the banned things in prose; only code counts.
        final code = line.split('//').first;
        for (final banned in _bannedIdentifiers) {
          expect(
            banned.hasMatch(code),
            isFalse,
            reason:
                '${file.path}: "${line.trim()}" references a '
                'side-effecting identifier',
          );
        }
      }
    }
  });

  test('a functional core is private to its shell', () {
    // The core is an implementation detail: it is deliberately NOT
    // re-exported, so its types never become package API. Nothing enforces
    // that in an app package (@internal only fires across packages, and
    // `part` would give a part file no imports for the purity scan above),
    // so this is the net: any other lib file importing a core fails the
    // build, and the fix is to reach for the shell's public surface instead.
    final lib = Directory('lib');
    final offenders = <String>[];
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final normalized = file.path.replaceAll('\\', '/');
      if (normalized == _shellOfFunctionalCore) continue;
      for (final line in file.readAsLinesSync()) {
        final directive = _importDirective.firstMatch(line);
        if (directive == null) continue;
        if (_functionalFile.hasMatch(directive.group(1)!)) {
          offenders.add('$normalized imports "${directive.group(1)}"');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'functional cores are private to $_shellOfFunctionalCore:\n'
          '${offenders.join('\n')}',
    );
  });
}
