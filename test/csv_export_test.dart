import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/csv_export.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// Tests for the pure CSV-building half of the export path (the plugin
/// dispatch half is platform code and stays untested).
void main() {
  const int channels = 2;
  const int sampleRate = 1000;

  List<ChannelCalibration> nominalCals() => [
    for (int ch = 0; ch < channels; ch++)
      ChannelCalibration(board: ChannelBoardCalibration()),
  ];

  SessionData makeSession(
    List<List<int>> perChannel, {
    List<ChannelCalibration>? calibrations,
    List<double>? tares,
    GapList? gaps,
  }) => SessionData(
    channels: [for (final values in perChannel) Int32List.fromList(values)],
    sampleRate: sampleRate,
    sampleCount: perChannel.first.length,
    calibrations: calibrations ?? nominalCals(),
    tares: tares ?? List.filled(channels, 0.0),
    gaps: gaps,
  );

  group('buildSessionCsv', () {
    test('emits header, time column, and raw values', () {
      final data = makeSession([
        [10, 20, 30],
        [-1, -2, -3],
      ]);

      final csv = buildSessionCsv(data, ['A', 'B']);
      final lines = csv.trim().split('\n');

      expect(lines[0], 'time_s,A_raw,A_kgf,B_raw,B_kgf');
      expect(lines[1], '0.0000,10,,-1,');
      expect(lines[2], '0.0010,20,,-2,');
      expect(lines[3], '0.0020,30,,-3,');
    });

    test('kgf column matches the session calibration converter', () {
      final cell = LoadCellProfile(capacityKg: 100, sensitivityMvV: 2.0);
      final cals = [
        ChannelCalibration(board: ChannelBoardCalibration(), loadCell: cell),
        ChannelCalibration(board: ChannelBoardCalibration()),
      ];
      final data = makeSession([
        [1000, 2000],
        [5, 6],
      ], calibrations: cals, tares: [100.0, 0.0]);

      final lines = buildSessionCsv(data, ['A', 'B']).trim().split('\n');

      String expectedKgf(int raw) => DisplayUnit.kgf
          .converterFor(cals[0], 100.0)!
          .call(raw.toDouble())
          .toStringAsFixed(6);

      expect(lines[1], '0.0000,1000,${expectedKgf(1000)},5,');
      expect(lines[2], '0.0010,2000,${expectedKgf(2000)},6,');
    });

    test('gap samples emit blank cells, not held values', () {
      final gaps = GapList()..append(1, 2); // half-open: only sample 1
      final data = makeSession([
        [10, 20, 30],
        [40, 50, 60],
      ], gaps: gaps);

      final lines = buildSessionCsv(data, ['A', 'B']).trim().split('\n');

      expect(lines[1], '0.0000,10,,40,');
      expect(lines[2], '0.0010,,,,');
      expect(lines[3], '0.0020,30,,60,');
    });

    test('labels needing quoting are escaped in the header', () {
      final data = makeSession([
        [1],
        [2],
      ]);

      final csv = buildSessionCsv(data, ['Load, top', 'Say "hi"']);
      final header = csv.split('\n').first;

      expect(
        header,
        'time_s,"Load, top"_raw,"Load, top"_kgf,'
        '"Say ""hi"""_raw,"Say ""hi"""_kgf',
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
      expect(csvFileNameForSession('a\\b:c*d?e"f<g>h|i'), 'a-b-c-d-e-f-g-h-i.csv');
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
