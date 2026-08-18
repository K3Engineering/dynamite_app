import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/csv_export.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// Tests for the pure CSV-building half of the export path (the plugin
/// dispatch half is platform code and stays untested). The format reference
/// is docs/csv-format-v1.md.
void main() {
  const int channels = 2;
  const int sampleRate = 1000;

  /// Fixed provenance for the metadata line: the app version string is
  /// injected by the plugin half, the wall clock by the session row.
  const generator = 'dynamite-flutter 1.0.0';
  final recordedAt = DateTime.utc(2026, 7, 29, 14, 5, 32);

  /// Pro-like test chain, reproducing the app's former compiled constants.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  List<ChannelCalibration> nominalCals() => [
    for (int ch = 0; ch < channels; ch++)
      ChannelCalibration(
        board: ChannelBoardCalibration(nominals: testNominals),
      ),
  ];

  SessionData makeSession(
    List<List<int>> perChannel, {
    List<ChannelCalibration>? calibrations,
    List<double>? tares,
    GapList? gaps,
    int? ssnOrigin,
  }) => SessionData(
    channels: [for (final values in perChannel) Int32List.fromList(values)],
    sampleRate: sampleRate,
    sampleCount: perChannel.first.length,
    calibrations: calibrations ?? nominalCals(),
    tares: tares ?? List.filled(channels, 0.0),
    gaps: gaps,
    ssnOrigin: ssnOrigin,
  );

  String buildCsv(SessionData data, DisplayUnit unit) =>
      buildSessionCsv(data, unit, recordedAt: recordedAt, generator: generator);

  /// The metadata line parsed as JSON (line index 1, `# ` prefix stripped).
  Map<String, dynamic> metadataOf(String csv) {
    final line = csv.split('\n')[1];
    expect(line, startsWith('# '));
    return jsonDecode(line.substring(2)) as Map<String, dynamic>;
  }

  group('buildSessionCsv', () {
    test('emits magic, quartet header, and ssn-keyed data rows', () {
      final data = makeSession([
        [10, 20, 30],
        [-1, -2, -3],
      ], ssnOrigin: 41230);

      final lines = buildCsv(data, DisplayUnit.kgf).trim().split('\n');

      expect(lines[0], '# dynamite-csv 1');
      expect(lines[1], startsWith('# {'));
      expect(lines[2], 'ssn,ch0,ch1,ch0_kgf,ch1_kgf');
      // ssn is an arithmetic progression from ssn_origin; with no load cell
      // assigned, both converted columns are all-blank (the file's '—').
      expect(lines[3], '41230,10,-1,,');
      expect(lines[4], '41231,20,-2,,');
      expect(lines[5], '41232,30,-3,,');
    });

    test('a missing ssnOrigin exports as origin 0', () {
      final data = makeSession([
        [7],
        [8],
      ]);

      final lines = buildCsv(data, DisplayUnit.mVv).trim().split('\n');

      expect(lines[3], startsWith('0,'));
      expect(metadataOf(buildCsv(data, DisplayUnit.mVv))['ssn_origin'], 0);
    });

    test('metadata line carries the spec schema from the frozen session', () {
      final boardCal = ChannelBoardCalibration(
        resistors: const [10001.2, 9.98, 10.01, 10.02, 9.99, 9998.7],
        readings: const [6383553.0, 3192096.0, 120.0, -3191776.0, -6383313.0],
        nominals: testNominals,
      );
      final cals = [
        ChannelCalibration(
          board: boardCal,
          loadCell: LoadCellProfile(
            name: 'Load cell 100 kg',
            capacityKg: 100,
            sensitivityMvV: 2.007,
          ),
        ),
        ChannelCalibration(
          board: ChannelBoardCalibration(nominals: testNominals),
        ),
      ];
      final data = makeSession(
        [
          [1],
          [2],
        ],
        calibrations: cals,
        tares: [-12340.5, 55.0],
        ssnOrigin: 41230,
      );

      final meta = metadataOf(buildCsv(data, DisplayUnit.kgf));

      expect(meta, {
        'format': 'dynamite-csv',
        'version': 1,
        'generator': 'dynamite-flutter 1.0.0',
        'recorded_at': '2026-07-29T14:05:32.000Z',
        'sample_rate_hz': 1000,
        'ssn_origin': 41230,
        'converted_unit': 'kgf',
        'device': {
          'name': null,
          'id': null,
          'model': null,
          'firmware': null,
          'manufacturer': null,
        },
        'afe': {
          'adc_ref_v': 1.2,
          'front_end_gain': 101.0,
          'adc_gain': [1, 1],
        },
        'channels': [
          {
            'load_cell': {
              'name': 'Load cell 100 kg',
              'capacity_kg': 100.0,
              'sensitivity_mv_v': 2.007,
            },
            'tare_raw': -12340.5,
            'board_cal': {
              'r': [10001.2, 9.98, 10.01, 10.02, 9.99, 9998.7],
              'raw': [6383553.0, 3192096.0, 120.0, -3191776.0, -6383313.0],
              // The resolved nominals rode along in the session snapshot.
              'n': {'fsr': 1.2, 'afe': 101.0, 'pga': 1.0, 'exc': 4.53},
            },
          },
          // Uncalibrated, cell-less channel: the honesty markers are null.
          {'load_cell': null, 'tare_raw': 55.0, 'board_cal': null},
        ],
      });
    });

    test('metadata line carries the frozen device identity', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      final meta = metadataOf(
        buildSessionCsv(
          data,
          DisplayUnit.kgf,
          recordedAt: recordedAt,
          generator: generator,
          deviceInfoJson:
              '{"name":"DS A4CF1208F51E","id":"A4CF1208F51E",'
              '"model":"Dynamite Sampler Pro Mk1","firmware":"v700P|v1.2.3",'
              '"manufacturer":"K3 Engineering"}',
        ),
      );

      expect(meta['device'], {
        'name': 'DS A4CF1208F51E',
        'id': 'A4CF1208F51E',
        'model': 'Dynamite Sampler Pro Mk1',
        'firmware': 'v700P|v1.2.3',
        'manufacturer': 'K3 Engineering',
      });
    });

    test('a malformed device block degrades to null placeholders', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      // Bad JSON and wrong-typed values both degrade to nulls rather than
      // failing the export (display-only metadata path).
      for (final json in ['{not json', '{"name":42}']) {
        final meta = metadataOf(
          buildSessionCsv(
            data,
            DisplayUnit.kgf,
            recordedAt: recordedAt,
            generator: generator,
            deviceInfoJson: json,
          ),
        );
        expect(meta['device'], {
          'name': null,
          'id': null,
          'model': null,
          'firmware': null,
          'manufacturer': null,
        });
      }
    });

    test(
      'converted columns match the frozen converter at column precision',
      () {
        final cell = LoadCellProfile(capacityKg: 100, sensitivityMvV: 2.0);
        final cals = [
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
            loadCell: cell,
          ),
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
          ),
        ];
        final data = makeSession(
          [
            [1000, 2000],
            [5, 6],
          ],
          calibrations: cals,
          tares: [100.0, 0.0],
        );

        final lines = buildCsv(data, DisplayUnit.kgf).trim().split('\n');

        final decimals = DisplayUnit.kgf.exportDecimalsFor(cals[0])!;
        String expectedKgf(int raw) => DisplayUnit.kgf
            .converterFor(cals[0], 100.0)!
            .call(raw.toDouble())
            .toStringAsFixed(decimals);

        expect(lines[3], '0,1000,5,${expectedKgf(1000)},');
        expect(lines[4], '1,2000,6,${expectedKgf(2000)},');
      },
    );

    test('gap rows keep their ssn with every sample cell blank', () {
      final gaps = GapList()..append(1, 2); // half-open: only sample 1
      final data = makeSession(
        [
          [10, 20, 30],
          [40, 50, 60],
        ],
        gaps: gaps,
        ssnOrigin: 41230,
      );

      final lines = buildCsv(data, DisplayUnit.mVv).trim().split('\n');

      String ssnOf(int row) => lines[3 + row].split(',').first;
      expect(ssnOf(0), '41230');
      expect(lines[4], '41231,,,,');
      expect(ssnOf(2), '41232');
      // The gap did not consume extra rows: dropped SSNs are the blank rows.
      expect(lines, hasLength(3 + 3));
    });

    test('mV/V header suffixes keep the slash verbatim', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      final lines = buildCsv(data, DisplayUnit.mVv).trim().split('\n');

      expect(lines[2], 'ssn,ch0,ch1,ch0_mV/V,ch1_mV/V');
      expect(
        metadataOf(buildCsv(data, DisplayUnit.mVv))['converted_unit'],
        'mV/V',
      );
    });

    test('raw quartet 2 is net counts (raw − tare), fractional, 1 decimal', () {
      final data = makeSession(
        [
          [1000],
          [5],
        ],
        tares: [100.3, 0.0],
      );

      final lines = buildCsv(data, DisplayUnit.raw).trim().split('\n');

      expect(lines[2], 'ssn,ch0,ch1,ch0_raw,ch1_raw');
      expect(lines[3], '0,1000,5,899.7,5.0');
    });
  });

  group('column precision (spec worked example: 100 kg / 2 mV/V cell, '
      'nominal chain)', () {
    final cal = ChannelCalibration(
      board: ChannelBoardCalibration(nominals: testNominals),
      loadCell: LoadCellProfile(capacityKg: 100, sensitivityMvV: 2.0),
    );

    // docs/csv-format-v1.md's table: decimals per unit for this setup.
    final expected = {
      DisplayUnit.kgf: 6,
      DisplayUnit.n: 5,
      DisplayUnit.lbf: 6,
      DisplayUnit.kN: 8,
      DisplayUnit.mVv: 8,
      DisplayUnit.mV: 7,
      DisplayUnit.raw: 1,
    };

    for (final entry in expected.entries) {
      test('${entry.key.symbol} → ${entry.value} decimals', () {
        expect(entry.key.exportDecimalsFor(cal), entry.value);
      });
    }

    test('a force unit on a cell-less channel has no precision (all-blank '
        'column)', () {
      expect(
        DisplayUnit.kgf.exportDecimalsFor(
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
          ),
        ),
        isNull,
      );
    });
  });

  group('csvFileNameForSession', () {
    test('replaces filename-hostile characters', () {
      expect(csvFileNameForSession('7/20 14:05:32'), '7-20 14-05-32.csv');
      expect(
        csvFileNameForSession('2026-07-29 14:05:32'),
        '2026-07-29 14-05-32.csv',
      );
      expect(
        csvFileNameForSession('a\\b:c*d?e"f<g>h|i'),
        'a-b-c-d-e-f-g-h-i.csv',
      );
    });

    test('trims trailing dots and spaces (illegal on Windows)', () {
      expect(csvFileNameForSession('pull test...'), 'pull test.csv');
      expect(csvFileNameForSession('name. '), 'name.csv');
    });

    test('strips leading dots (hidden files on macOS/Linux)', () {
      expect(csvFileNameForSession('.notes'), 'notes.csv');
      expect(csvFileNameForSession('..pull test'), 'pull test.csv');
    });

    test('falls back to session.csv for empty or fully-trimmed names', () {
      expect(csvFileNameForSession(''), 'session.csv');
      expect(csvFileNameForSession('...'), 'session.csv');
    });

    test('disambiguates Windows reserved device names', () {
      expect(csvFileNameForSession('con'), 'con_.csv');
      expect(csvFileNameForSession('NUL'), 'NUL_.csv');
      expect(csvFileNameForSession('com3'), 'com3_.csv');
      expect(csvFileNameForSession('lpt9'), 'lpt9_.csv');
      // Reserved with an extension too: "con.txt.csv" is as refused as "con".
      expect(csvFileNameForSession('con.txt'), 'con_.txt.csv');
      // …but longer names merely starting with a reserved word are fine.
      expect(csvFileNameForSession('com10'), 'com10.csv');
      expect(csvFileNameForSession('auxiliary'), 'auxiliary.csv');
    });
  });
}
