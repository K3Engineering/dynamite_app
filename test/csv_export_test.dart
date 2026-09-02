import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/channel_converter.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/csv_export.dart';
import 'package:dynamite_app/services/session_data.dart';

/// Tests for the pure CSV-building half of the export path (the plugin
/// dispatch half is platform code and stays untested). The format reference
/// is csv-format-v1C.md.
void main() {
  const int channels = 2;
  const int sampleRate = 1000;

  /// Fixed provenance for the metadata line: the app version string is
  /// injected by the plugin half, the frozen recorded_at string by the
  /// session row (recorded_unix derives from it at export).
  const generator = 'dynamite-flutter 1.0.0';
  const recordedAtIso = '2026-07-29T14:05:32.000Z';
  final recordedUnix =
      DateTime.parse(recordedAtIso).millisecondsSinceEpoch ~/ 1000;

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
    List<double?>? tares,
    GapList? gaps,
    int ssnOrigin = 0,
    SessionBoardMeta? boardMeta,
  }) => SessionData(
    channels: [for (final values in perChannel) Int32List.fromList(values)],
    sampleRate: sampleRate,
    sampleCount: perChannel.first.length,
    calibrations: calibrations ?? nominalCals(),
    tares: tares ?? List.filled(channels, null),
    gaps: gaps,
    ssnOrigin: ssnOrigin,
    boardMeta: boardMeta,
  );

  String buildCsv(SessionData data, DisplayUnit unit) => buildSessionCsv(
    data,
    unit,
    recordedAtIso: recordedAtIso,
    generator: generator,
  );

  /// The metadata line parsed as JSON (line index 1, `# ` prefix stripped).
  Map<String, dynamic> metadataOf(String csv) {
    final line = csv.split('\n')[1];
    expect(line, startsWith('# '));
    return jsonDecode(line.substring(2)) as Map<String, dynamic>;
  }

  /// The file's non-comment lines: index 0 is the header row, then one data
  /// row per sample. This is the v1C consumer contract — data begins at the
  /// first line not starting with `#`, never at a fixed line number.
  List<String> bodyOf(String csv) =>
      csv.trim().split('\n').skipWhile((l) => l.startsWith('#')).toList();

  group('buildSessionCsv', () {
    test('emits magic, quartet header, and ssn-keyed data rows', () {
      final data = makeSession([
        [10, 20, 30],
        [-1, -2, -3],
      ], ssnOrigin: 41230);

      final lines = buildCsv(data, DisplayUnit.kgf).split('\n');
      final body = bodyOf(buildCsv(data, DisplayUnit.kgf));

      expect(lines[0], '# dynamite-csv 1');
      expect(lines[1], startsWith('# {'));
      expect(body[0], 'ssn,ch0,ch1,ch0_kgf,ch1_kgf');
      // ssn is an arithmetic progression from ssn_origin; with no load cell
      // assigned, both converted columns are all-blank (the file's '—').
      expect(body[1], '41230,10,-1,,');
      expect(body[2], '41231,20,-2,,');
      expect(body[3], '41232,30,-3,,');
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
        'recorded_unix': recordedUnix,
        'sample_rate_hz': 1000,
        'ssn_origin': 41230,
        'converted_unit': 'kgf',
        'device': {
          'name': null,
          'id': null,
          'model': null,
          'hardware_rev': null,
          'firmware': null,
          'manufacturer': null,
          'afe': {
            'adc_ref_v': 1.2,
            'front_end_gain': 101.0,
            'adc_gain': [1, 1],
            'excitation_v': 4.53,
          },
          'cal': null,
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

    test('the interrupted disclosure is additive: present only when set', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      // A complete session exports exactly the v1 schema — no key at all.
      expect(
        metadataOf(buildCsv(data, DisplayUnit.kgf)),
        isNot(contains('interrupted')),
      );

      final interruptedMeta = metadataOf(
        buildSessionCsv(
          data,
          DisplayUnit.kgf,
          recordedAtIso: recordedAtIso,
          generator: generator,
          interrupted: true,
        ),
      );
      expect(interruptedMeta['interrupted'], isTrue);
      expect(interruptedMeta['sample_rate_hz'], 1000);
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
          recordedAtIso: recordedAtIso,
          generator: generator,
          deviceInfo: const {
            'name': 'DS A4CF1208F51E',
            'id': 'A4CF1208F51E',
            'model': 'Dynamite Sampler Pro Mk1',
            'hardware_rev': 'rev B',
            'firmware': 'v700P|v1.2.3',
            'manufacturer': 'K3 Engineering',
          },
        ),
      );

      expect(meta['device'], {
        'name': 'DS A4CF1208F51E',
        'id': 'A4CF1208F51E',
        'model': 'Dynamite Sampler Pro Mk1',
        'hardware_rev': 'rev B',
        'firmware': 'v700P|v1.2.3',
        'manufacturer': 'K3 Engineering',
        'afe': {
          'adc_ref_v': 1.2,
          'front_end_gain': 101.0,
          'adc_gain': [1, 1],
          'excitation_v': 4.53,
        },
        'cal': null,
      });
    });

    test('the board-cal provenance joins the device block as cal', () {
      const boardMeta = SessionBoardMeta(
        factoryDate: '2026-06-14',
        calBoardId: 'CB42 v1.0.3',
        calTool: 'calibrate v3.1',
        calOrigin: 'factory',
        calTempsC: (dut: 23.8, calBoard: 24.1),
        calAdcGains: [1, 1, 1, 1],
        calDataInvalid: false,
        constantsStatus: BoardDataStatus.ok,
        constantsDetail: '',
        provenance: {'exc': 'nominal'},
      );
      final data = makeSession([
        [1],
        [2],
      ], boardMeta: boardMeta);

      final csv = buildCsv(data, DisplayUnit.kgf);
      final meta = metadataOf(csv);

      expect((meta['device'] as Map)['cal'], {
        'cal_date': '2026-06-14',
        'cal_board': 'CB42 v1.0.3',
        'cal_tool': 'calibrate v3.1',
        'cal_origin': 'factory',
        'cal_temp': [23.8, 24.1],
        'cal_adc': [1, 1, 1, 1],
        'cal_data_invalid': false,
        'constants_status': 'ok',
        'constants_detail': '',
        'provenance': {'exc': 'nominal'},
      });
      // The human rendering reflects it too (nested one more under device).
      expect(csv, contains('#   cal:'));
      expect(csv, contains('#     cal_data_invalid: false'));
      expect(csv, contains("#       exc: 'nominal'"));
    });

    test('a session recorded with no board meta exports cal as null', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      final meta = metadataOf(buildCsv(data, DisplayUnit.kgf));

      expect((meta['device'] as Map)['cal'], isNull);
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

        final body = bodyOf(buildCsv(data, DisplayUnit.kgf));

        final conv = ChannelConverter(cals[0], 100.0);
        final decimals = DisplayUnit.kgf.exportDecimalsFor(conv)!;
        String expectedKgf(int raw) => conv
            .netMap(DisplayUnit.kgf)!(raw.toDouble())
            .toStringAsFixed(decimals);

        expect(body[1], '0,1000,5,${expectedKgf(1000)},');
        expect(body[2], '1,2000,6,${expectedKgf(2000)},');
      },
    );

    test('a null tare exports gross, not blanks', () {
      final cell = LoadCellProfile(capacityKg: 100, sensitivityMvV: 2.0);
      final cals = [
        for (int ch = 0; ch < channels; ch++)
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
            loadCell: cell,
          ),
      ];
      final data = makeSession(
        [
          [1000],
          [2000],
        ],
        calibrations: cals,
        tares: [100.0, null],
      );

      final csv = buildCsv(data, DisplayUnit.kgf);
      final body = bodyOf(csv);
      final decimals = DisplayUnit.kgf.exportDecimalsFor(
        ChannelConverter(cals[0], null),
      )!;
      String expected(int raw, double? tare) => ChannelConverter(
        cals[0],
        tare,
      ).netMap(DisplayUnit.kgf)!(raw.toDouble()).toStringAsFixed(decimals);

      // One sample: ch0 nets through its frozen tare, ch1 converts gross.
      expect(
        body[1],
        '0,1000,2000,${expected(1000, 100.0)},'
        '${expected(2000, null)}',
      );
      final meta = metadataOf(csv);
      expect((meta['channels'] as List)[1]['tare_raw'], isNull);
    });

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

      final body = bodyOf(buildCsv(data, DisplayUnit.mVv));

      String ssnOf(int row) => body[1 + row].split(',').first;
      expect(ssnOf(0), '41230');
      expect(body[2], '41231,,,,');
      expect(ssnOf(2), '41232');
      // The gap did not consume extra rows: dropped SSNs are the blank rows.
      expect(body, hasLength(1 + 3));
    });

    test('mV/V header suffixes keep the slash verbatim', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      final body = bodyOf(buildCsv(data, DisplayUnit.mVv));

      expect(body[0], 'ssn,ch0,ch1,ch0_mV/V,ch1_mV/V');
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

      final body = bodyOf(buildCsv(data, DisplayUnit.raw));

      expect(body[0], 'ssn,ch0,ch1,ch0_raw,ch1_raw');
      expect(body[1], '0,1000,5,899.7,5.0');
    });
  });

  group('YAML comment block (csv-format-v1C §The two renderings)', () {
    test('renders the closed schema canonically', () {
      final lines = yamlLinesForCsvMetadata({
        'str': "John's cell",
        'num_i': 1,
        'num_f': 2.007,
        'truth': true,
        'lying': false,
        'absent': null,
        'flow': [1, 4.53, 'x'],
        'empty_list': <Object?>[],
        'empty_map': <String, Object?>{},
        'mapping': {'x': 1, 'y': null},
        'sequence': [
          {
            'm': 'v1',
            'n': [4.53],
            'o': {'p': false},
          },
          {'m': null, 'n': <Object?>[], 'o': null},
        ],
      });

      expect(lines, [
        "str: 'John''s cell'",
        'num_i: 1',
        'num_f: 2.007',
        'truth: true',
        'lying: false',
        'absent: null',
        "flow: [1, 4.53, 'x']",
        'empty_list: []',
        'empty_map: {}',
        'mapping:',
        '  x: 1',
        '  y: null',
        'sequence:',
        "  - m: 'v1'",
        '    n: [4.53]',
        '    o:',
        '      p: false',
        '  - m: null',
        '    n: []',
        '    o: null',
      ]);
    });

    test('throws on values outside the closed schema', () {
      expect(
        () => yamlLinesForCsvMetadata({
          'bad': {'when': DateTime.utc(2026)},
        }),
        throwsArgumentError,
      );
      expect(
        () => yamlLinesForCsvMetadata({
          'bad': [<String, Object?>{}],
        }),
        throwsArgumentError,
      );
    });

    test('the block re-renders byte-identically from line 2 (the validator '
        'path: re-render and byte-compare without parsing YAML)', () {
      final cals = [
        ChannelCalibration(
          board: ChannelBoardCalibration(
            resistors: const [10001.2, 9.98, 10.01, 10.02, 9.99, 9998.7],
            readings: const [
              6383553.0,
              3192096.0,
              120.0,
              -3191776.0,
              -6383313.0,
            ],
            nominals: testNominals,
          ),
          loadCell: LoadCellProfile(
            name: "John Smith's 100 kg",
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
        boardMeta: const SessionBoardMeta(
          factoryDate: '2026-06-14',
          calDataInvalid: false,
          constantsStatus: BoardDataStatus.ok,
          constantsDetail: '',
          provenance: {},
        ),
      );

      final csv = buildCsv(data, DisplayUnit.kgf);
      final lines = csv.trim().split('\n');
      final commentLines = lines.takeWhile((l) => l.startsWith('#')).toList();

      final reparsed = jsonDecode(commentLines[1].substring(2));
      final rerendered = yamlLinesForCsvMetadata(
        reparsed as Map<String, dynamic>,
      );
      expect(commentLines.sublist(2), [
        for (final line in rerendered) '# $line',
      ]);
    });
  });

  group('column precision (spec worked example: 100 kg / 2 mV/V cell, '
      'nominal chain)', () {
    final cal = ChannelCalibration(
      board: ChannelBoardCalibration(nominals: testNominals),
      loadCell: LoadCellProfile(capacityKg: 100, sensitivityMvV: 2.0),
    );

    // csv-format-v1.md's table: decimals per unit for this setup.
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
        expect(
          entry.key.exportDecimalsFor(ChannelConverter(cal, null)),
          entry.value,
        );
      });
    }

    test('a force unit on a cell-less channel has no precision (all-blank '
        'column)', () {
      expect(
        DisplayUnit.kgf.exportDecimalsFor(
          ChannelConverter(
            ChannelCalibration(
              board: ChannelBoardCalibration(nominals: testNominals),
            ),
            null,
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
