import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for the PURE model layer (lib/models/**.dart only —
/// widgets and services are out of scope by design): no construct that can
/// break determinism may appear in those files, so the models stay
/// testable, replayable, and free of hidden side effects.
///
/// Tests run on the VM with CWD = repo root, so `lib/models` resolves
/// directly via dart:io.
void main() {
  /// Determinism-breaking constructs that must not appear in lib/models.
  const banned = [
    'DateTime.now',
    'DateTime.timestamp',
    'Stopwatch(',
    'identityHashCode(',
    'dart:io',
    'Random(',
    'Timer(',
    'Future.delayed',
  ];

  /// (file, pattern) hits that are legitimate. Every entry must still match
  /// its hit — a stale entry fails the test — so the allowlist cannot drift
  /// out of sync with the sources it excuses.
  const allowed = {
    // deriveFeedHealth takes an injected clock (`now`); DateTime.now appears
    // only as the DEFAULT when no clock is passed, keeping every call site
    // deterministically testable.
    ('lib/models/feed_health.dart', 'DateTime.now'),
  };

  /// package:flutter/* / dart:ui imports allowed per file, with
  /// justifications. Same stale-entry rule as above.
  const allowedImports = {
    // debugPrint (diagnostics) and listEquals only — no widget/rendering
    // dependency, and both come from the pure foundation library.
    'lib/models/load_cell.dart': {
      'package:flutter/foundation.dart': 'debugPrint + listEquals only',
    },
    // Listenable/VoidCallback are the repaint-contract types of the
    // GraphDataSource interface; foundation is pure Dart (no dart:ui).
    'lib/models/graph_data_source.dart': {
      'package:flutter/foundation.dart':
          'Listenable/VoidCallback repaint contract',
    },
  };

  List<File> modelFiles() => Directory('lib/models')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('no lib/models file contains determinism-breaking constructs', () {
    final violations = <String>[];
    // Tracks which allowlist entries were actually hit.
    final matched = <(String, String)>{};

    for (final file in modelFiles()) {
      final path = file.path.replaceAll(r'\', '/');
      final text = file.readAsStringSync();
      final lines = text.split('\n');
      for (final pattern in banned) {
        for (int i = 0; i < lines.length; i++) {
          if (!lines[i].contains(pattern)) continue;
          final key = (path, pattern);
          if (allowed.contains(key)) {
            matched.add(key);
          } else {
            violations.add('$path:${i + 1}: contains "$pattern"');
          }
        }
      }
    }

    for (final entry in allowed) {
      if (!matched.contains(entry)) {
        violations.add('stale allowlist entry: ${entry.$1} / "${entry.$2}"');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('no lib/models file imports package:flutter/* or dart:ui', () {
    final importRe = RegExp("^import '[^']+'", multiLine: true);
    final violations = <String>[];
    final matched = <String>{};

    for (final file in modelFiles()) {
      final path = file.path.replaceAll(r'\', '/');
      final text = file.readAsStringSync();
      for (final m in importRe.allMatches(text)) {
        final target = m[0]!.substring("import '".length, m[0]!.length - 1);
        final isFlutter =
            target.startsWith('package:flutter/') ||
            target.startsWith('dart:ui');
        if (!isFlutter) continue;
        if (allowedImports[path]?.containsKey(target) ?? false) {
          matched.add('$path|$target');
        } else {
          violations.add('$path: imports "$target"');
        }
      }
    }

    for (final entry in allowedImports.entries) {
      for (final target in entry.value.keys) {
        if (!matched.contains('${entry.key}|$target')) {
          violations.add('stale allowlist entry: ${entry.key} / "$target"');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
