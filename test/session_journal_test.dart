import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/services/session_journal.dart';

/// The session journal (session_journal.dart): a strict line-1 header, whole
/// -snapshot edit lines with last-complete-line-wins, append-only damage
/// shapes (torn meta, torn edits) and the byte offsets the append
/// discipline needs.
void main() {
  final meta = SessionMeta(
    name: 'lift 1',
    sampleRate: 1000,
    channelCount: 4,
    channelLabels: ['a', 'b', 'c', 'd'],
    tares: [null, 12.5, -3.25, null],
    calibration: [
      ChannelCalibration(board: ChannelBoardCalibration()),
      ChannelCalibration(board: ChannelBoardCalibration()),
      ChannelCalibration(board: ChannelBoardCalibration()),
      ChannelCalibration(board: ChannelBoardCalibration()),
    ],
    displayUnit: 'kgf',
    deviceInfo: {'model': 'dyna-1', 'fw': '1.2.3'},
    boardMeta: const SessionBoardMeta(
      calDataInvalid: false,
      constantsStatus: BoardDataStatus.ok,
      constantsDetail: '',
      provenance: {'adc_fsr': 'nominal'},
    ),
    recordedAt: '2026-08-28T14:30:12.345+02:00',
    ssnOrigin: 98765,
    visibleChannels: [true, false, true, true],
  );

  const edit1 = SessionEdit(
    name: 'lift 1 (edited)',
    notes: 'nailed it',
    visibleChannels: [false, true, true, true],
  );
  const edit2 = SessionEdit(
    name: 'lift 1 (v2)',
    notes: 'second thoughts',
    visibleChannels: [true, true, true, true],
  );

  group('SessionMeta strict parse', () {
    test('round-trips every field', () {
      final journal = parseSessionJournal(encodeSessionMeta(meta));
      expect(journal.meta.name, meta.name);
      expect(journal.meta.sampleRate, meta.sampleRate);
      expect(journal.meta.channelCount, meta.channelCount);
      expect(journal.meta.channelLabels, meta.channelLabels);
      expect(journal.meta.tares, meta.tares);
      expect(journal.meta.displayUnit, meta.displayUnit);
      expect(journal.meta.deviceInfo, meta.deviceInfo);
      expect(journal.meta.boardMeta, isNotNull);
      expect(journal.meta.boardMeta!.constantsStatus, BoardDataStatus.ok);
      expect(journal.meta.recordedAt, meta.recordedAt);
      expect(journal.meta.ssnOrigin, meta.ssnOrigin);
      expect(journal.meta.visibleChannels, meta.visibleChannels);
      expect(journal.edit, isNull);
      expect(journal.completeBytes, encodeSessionMeta(meta).length);
    });

    test('null boardMeta round-trips as null', () {
      final bare = SessionMeta(
        name: '',
        sampleRate: 500,
        channelCount: 4,
        channelLabels: ['a', 'b', 'c', 'd'],
        tares: [null, null, null, null],
        calibration: [
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
        ],
        displayUnit: 'mVv',
        deviceInfo: {},
        boardMeta: null,
        recordedAt: '2026-08-28T14:30:12.345Z',
        ssnOrigin: 0,
        visibleChannels: [true, true, true, true],
      );
      expect(
        parseSessionJournal(encodeSessionMeta(bare)).meta.boardMeta,
        isNull,
      );
    });

    Map<String, dynamic> metaJson([void Function(Map<String, dynamic>)? f]) {
      final json = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(meta.toJson())),
      );
      f?.call(json);
      return json;
    }

    test('rejects a different version', () {
      final bad = jsonEncode(metaJson((j) => j['version'] = 2));
      expect(
        () => parseSessionJournal(utf8.encode('$bad\n')),
        throwsFormatException,
      );
    });

    test('rejects wrong types and wrong list lengths', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (Map<String, dynamic> j) => j['sampleRate'] = 0,
        (Map<String, dynamic> j) => j['sampleRate'] = '1000',
        (Map<String, dynamic> j) => j['channelCount'] = 0,
        (Map<String, dynamic> j) => j['channelLabels'] = ['a'],
        (Map<String, dynamic> j) => j['tares'] = [null, 'x', null, null],
        (Map<String, dynamic> j) => j['calibration'] = <Map<String, dynamic>>[],
        (Map<String, dynamic> j) => j['visibleChannels'] = [1, 2, 3, 4],
        (Map<String, dynamic> j) => j['displayUnit'] = '',
        (Map<String, dynamic> j) => j['displayUnit'] = 'kg', // not a unit
        (Map<String, dynamic> j) => j['deviceInfo'] = 'nope',
        (Map<String, dynamic> j) => j['recordedAt'] = '',
        (Map<String, dynamic> j) => j['recordedAt'] = 'yesterday', // no ISO
        (Map<String, dynamic> j) => j['ssnOrigin'] = 1.5,
        (Map<String, dynamic> j) => j['boardMeta'] = 42,
      ]) {
        final bad = jsonEncode(metaJson(mutate));
        expect(
          () => parseSessionJournal(utf8.encode('$bad\n')),
          throwsFormatException,
          reason: 'mutation should fail: $bad',
        );
      }
    });

    test('unknown keys are ignored', () {
      final json = jsonEncode(metaJson((j) => j['futureField'] = {'x': 1}));
      expect(parseSessionJournal(utf8.encode('$json\n')).meta.name, meta.name);
    });

    test('damaged line 1 throws', () {
      expect(
        () => parseSessionJournal(utf8.encode('not json\n')),
        throwsFormatException,
      );
      expect(
        () => parseSessionJournal(utf8.encode('[1,2]\n')),
        throwsFormatException,
      );
      expect(
        () => parseSessionJournal(utf8.encode('{"version":1\n')),
        throwsFormatException,
      );
      expect(() => parseSessionJournal(utf8.encode('')), throwsFormatException);
    });
  });

  group('edits', () {
    test('the last complete edit line wins', () {
      final bytes = concatBytes([
        encodeSessionMeta(meta),
        encodeSessionEdit(edit1),
        encodeSessionEdit(edit2),
      ]);
      final journal = parseSessionJournal(bytes);
      expect(journal.edit!.name, edit2.name);
      expect(journal.edit!.notes, edit2.notes);
      expect(journal.effectiveEdit.name, edit2.name);
    });

    test('no edit line: effective state falls back to the meta', () {
      final journal = parseSessionJournal(encodeSessionMeta(meta));
      expect(journal.effectiveEdit.name, meta.name);
      expect(journal.effectiveEdit.notes, '');
      expect(journal.effectiveEdit.visibleChannels, meta.visibleChannels);
    });

    test('a torn trailing edit loses only that edit', () {
      final torn = utf8.encode('{"name":"hal');
      final bytes = concatBytes([
        encodeSessionMeta(meta),
        encodeSessionEdit(edit1),
        torn,
      ]);
      final journal = parseSessionJournal(bytes);
      expect(journal.edit!.name, edit1.name);
      expect(
        journal.completeBytes,
        encodeSessionMeta(meta).length + encodeSessionEdit(edit1).length,
      );
    });

    test('a complete malformed edit line is corruption, not a tear', () {
      // Newline-terminated garbage is persisted corruption: the write path
      // appends whole lines, so a complete line that fails to parse must
      // fail loudly instead of silently keeping the preceding edit.
      final bytes = concatBytes([
        encodeSessionMeta(meta),
        utf8.encode('garbage\n'),
        encodeSessionEdit(edit1),
      ]);
      expect(() => parseSessionJournal(bytes), throwsFormatException);
    });
  });

  group('non-ASCII content', () {
    test('byte offsets stay correct with multi-byte UTF-8 in names/notes', () {
      final foreignMeta = SessionMeta(
        name: 'Seßión ünïcode',
        sampleRate: 1000,
        channelCount: 4,
        channelLabels: ['a', 'b', 'c', 'd'],
        tares: [null, null, null, null],
        calibration: [
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
          ChannelCalibration(board: ChannelBoardCalibration()),
        ],
        displayUnit: 'kgf',
        deviceInfo: {'note': 'mañana'},
        boardMeta: null,
        recordedAt: '2026-08-28T14:30:12.345Z',
        ssnOrigin: 1,
        visibleChannels: [true, true, true, true],
      );
      const foreignEdit = SessionEdit(
        name: 'grüße goß',
        notes: 'héllo wörld ü',
        visibleChannels: [true, true, true, true],
      );
      final bytes = concatBytes([
        encodeSessionMeta(foreignMeta),
        encodeSessionEdit(foreignEdit),
      ]);
      final journal = parseSessionJournal(bytes);
      expect(journal.edit!.notes, foreignEdit.notes);
      expect(journal.completeBytes, bytes.length);
    });
  });
}

Uint8List concatBytes(List<List<int>> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}
