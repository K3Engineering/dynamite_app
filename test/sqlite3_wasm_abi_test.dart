import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Guards the hand-maintained web artifacts against version skew with the
/// sqlite3 package locked in pubspec.lock — the skew that crashes the web
/// app at first database open with "WebAssembly.instantiate(): Import #N ...
/// module is not an object or function".
///
/// The wasm binary carries no version marker, so the check is structural:
/// the namespaces it imports host functions from must be ones the resolved
/// sqlite3 package's loader actually provides.
void main() {
  test('web/sqlite3.wasm matches the locked sqlite3 package ABI', () {
    final wasm = File('web/sqlite3.wasm');
    if (!wasm.existsSync()) {
      fail(
        'web/sqlite3.wasm is missing — double-check it was downloaded from '
        'the sqlite3.dart release matching the locked sqlite3 version.',
      );
    }

    final (version, major) = _lockedSqlite3Version();
    // Import namespaces each sqlite3 major's wasm loader provides, from its
    // loader source: 2.x installs `dart` + `env` (memory import), 3.x
    // installs `dart` only (memory is exported). Revisit on major bumps.
    final provided = switch (major) {
      2 => {'dart', 'env'},
      _ => {'dart'},
    };

    final imported = {
      for (final i in _wasmImports(wasm.readAsBytesSync())) i.module,
    };

    expect(
      imported,
      contains('dart'),
      reason: 'web/sqlite3.wasm imports nothing from `dart` — it is not a '
          'package:sqlite3 build. Double-check it against pubspec.lock.',
    );
    expect(
      imported.difference(provided),
      isEmpty,
      reason: 'web/sqlite3.wasm imports namespaces the loader of sqlite3 '
          '$version does not provide — double-check web/sqlite3.wasm matches '
          'the locked sqlite3 version ($version).',
    );
  });

  test('drift_worker.js was compiled against the locked sqlite3', () {
    // drift_worker.js.deps is gitignored: it only exists on machines where
    // the worker was compiled, never in CI. The check applies there.
    final deps = File('web/drift_worker.js.deps');
    if (!deps.existsSync()) return;

    final compiledAgainst = RegExp(
      r'sqlite3-(\d+\.\d+\.\d+)',
    ).firstMatch(deps.readAsStringSync())?[1];

    expect(
      compiledAgainst,
      _lockedSqlite3Version().$1,
      reason: 'drift_worker.js is stale — double-check it was recompiled '
          'after the last sqlite3 bump.',
    );
  });
}

/// The locked sqlite3 version as `('x.y.z', major)`, parsed from the
/// pub-cache path in .dart_tool/package_config.json.
(String, int) _lockedSqlite3Version() {
  final config = File('.dart_tool/package_config.json').readAsStringSync();
  final m = RegExp(r'sqlite3-(\d+)\.(\d+)\.(\d+)').firstMatch(config);
  if (m == null) {
    fail('Could not determine the locked sqlite3 version.');
  }
  return ('${m[1]}.${m[2]}.${m[3]}', int.parse(m[1]!));
}

/// The (module, name) pairs a wasm binary imports, read out of its import
/// section. Just enough of the binary format to walk sections and the import
/// vector — no validation beyond that.
List<({String module, String name})> _wasmImports(Uint8List bytes) {
  var pos = 8; // magic + version

  int readU32() {
    var value = 0, shift = 0, byte = 0;
    do {
      byte = bytes[pos++];
      value |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80 != 0);
    return value;
  }

  String readName() {
    final length = readU32();
    final name = utf8.decode(bytes.sublist(pos, pos + length));
    pos += length;
    return name;
  }

  void skipLimits() {
    final flags = readU32();
    readU32();
    if (flags & 1 != 0) readU32();
  }

  final imports = <({String module, String name})>[];
  while (pos < bytes.length) {
    final sectionId = bytes[pos++];
    final sectionSize = readU32();
    if (sectionId != 2) {
      pos += sectionSize; // not the import section
      continue;
    }
    for (var i = 0, count = readU32(); i < count; i++) {
      final module = readName();
      final name = readName();
      switch (bytes[pos++]) {
        case 0: // function: type index
          readU32();
        case 1: // table: element type, then limits
          pos++;
          skipLimits();
        case 2: // memory: limits
          skipLimits();
        case 3: // global: value type + mutability
          pos += 2;
      }
      imports.add((module: module, name: name));
    }
    break;
  }
  return imports;
}
