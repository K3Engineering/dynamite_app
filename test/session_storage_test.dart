import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/channel_converter.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_data.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// Storage-side session tests.
///
/// An in-memory database is installed for every test in this file: several
/// tests exercise the real DB path (the writer creates the session row on
/// its first chunk flush); the rest substitute no-op or stallable sinks.
void main() {
  const int channels = kAdcChannelCount;

  setUp(() {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(AppDatabase.closeInstance);

  List<ChannelCalibration> nominalCals() => [
    for (int ch = 0; ch < channels; ch++)
      ChannelCalibration(board: ChannelBoardCalibration()),
  ];

  /// startSession with the caller-side hub snapshots production now passes
  /// explicitly (see SessionStorage.startSession's hub-agnostic contract).
  /// Establishes the packet counter anchor the writer requires (in production
  /// packets precede samples, so an anchor always precedes the first append);
  /// tests that assert specific anchor behavior set their own.
  LiveSessionWriter startFromHub(DataHub hub, {required String name}) {
    if (hub.packetAnchor == null) {
      hub.notePacketCounter(0);
    }
    return SessionStorage.startSession(
      tare: hub.tare,
      channelCalibration: [
        for (int ch = 0; ch < channels; ch++) hub.calibrationFor(ch),
      ],
      samplesPerSec: hub.sampleRateHz,
      sourceRingCapacity: DataHub.maxDataSz,
      name: name,
      channelLabels: const ['a', 'b', 'c', 'd'],
      visibleChannels: const [true, true, true, true],
      displayUnit: DisplayUnit.kgf,
      deviceMetadata: const {},
      boardMeta: switch (hub.boardCalibration) {
        final board? => SessionBoardMeta.fromBoard(board),
        null => null,
      },
    );
  }

  /// A writer constructed without SessionStorage still needs the row header
  /// its first flush creates (see AppDatabase.createSessionWithFirstChunk).
  SessionHeader testHeader() => (
    name: '',
    sampleRate: 1000,
    channelCount: channels,
    channelLabels: '[]',
    tares: '[]',
    calibrationJson: '[]',
    visibleChannels: '[]',
    displayUnit: 'kgf',
    deviceInfoJson: '{}',
    boardMetaJson: null,
    recordedAt: '2026-07-29T14:05:32.000Z',
  );

  group('SessionData.channelExtremes', () {
    SessionData makeSession(List<int> values) => SessionData(
      channels: [
        for (int ch = 0; ch < channels; ch++) Int32List.fromList(values),
      ],
      sampleRate: 1000,
      sampleCount: values.length,
      calibrations: nominalCals(),
      tares: List.filled(channels, 0.0),
      ssnOrigin: 0,
    );

    test('a never-positive channel reports its true (negative) peaks', () {
      final sess = makeSession([-100, -300, -50, -200]);
      expect(sess.channelExtremes(0), (-300.0, -50.0));
    });

    test('an empty session has no extremes', () {
      final sess = makeSession(const []);
      expect(sess.channelExtremes(0), isNull);
    });
  });

  group('LiveSessionWriter ring-buffer safety', () {
    /// Pump samples like the decoder does: packets precede samples, so the
    /// first call also seeds the packet-counter anchor the writer requires.
    void pumpSamples(DataHub hub, Int32List frame, int count, int value) {
      hub.notePacketCounter(0);
      for (int ch = 0; ch < channels; ch++) {
        frame[ch] = value;
      }
      for (int i = 0; i < count; i++) {
        hub.addSampleFrame(frame);
      }
    }

    test('a slice is snapshotted at call time, not at dequeue time', () async {
      final saved = <Uint8List>[];
      final writer = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: DataHub.maxDataSz,
        chunkSink: (sessionId, chunkIndex, data, gapsJson) async {
          saved.add(data);
          return sessionId ?? 1;
        },
      );
      final hub = DataHub();
      // Packets precede samples: seed the encoder's counter anchor the
      // writer requires before any append.
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      const n = 50;
      for (int i = 0; i < n; i++) {
        for (int ch = 0; ch < channels; ch++) {
          frame[ch] = i;
        }
        hub.addSampleFrame(frame);
      }

      // Enqueue, then keep the producer busy before the queued op can drain
      // (it runs in a microtask, which this synchronous pump never yields to).
      unawaited(writer.appendData(hub.snapshotRange(0, n)));
      pumpSamples(hub, frame, 1000, 100000); // much larger values, no wrap

      await writer.flush();
      expect(writer.hasError, isFalse);
      expect(writer.totalSamplesRecorded, n);

      // The persisted chunk holds the call-time values, byte for byte.
      expect(saved, hasLength(1));
      final stored = ByteData.sublistView(saved.single);
      expect(stored.lengthInBytes, n * channels * 4);
      for (int s = 0; s < n; s++) {
        for (int ch = 0; ch < channels; ch++) {
          expect(stored.getInt32((s * channels + ch) * 4, Endian.little), s);
        }
      }
    });

    test('a storage stall past a ring of backlog latches an error and '
        'truncates the recording', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final saved = <Uint8List>[];
      var sinkCalls = 0;
      // Test-scale ring capacity: the latch then needs only ~2 stalled
      // chunks of backlog instead of a real 10-minute ring.
      const ringCapacity = 4096;
      final writer = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: ringCapacity,
        chunkSink: (sessionId, chunkIndex, data, gapsJson) async {
          sinkCalls++;
          if (!entered.isCompleted) entered.complete();
          await gate.future; // wedge every chunk write until released
          saved.add(data);
          return sessionId ?? 1;
        },
      );
      final hub = DataHub();
      final frame = Int32List(channels);

      // Fill the staging buffer past the 16 KB flush threshold so the first
      // chunk write goes in flight and blocks inside the sink.
      const chunkSamples = 2048; // 2048 * 4 ch * 4 B = 32 KB > 16 KB
      pumpSamples(hub, frame, chunkSamples, 7);
      unawaited(writer.appendData(hub.snapshotRange(0, chunkSamples)));
      await entered.future; // the queue is now stuck behind the gated write

      // The producer keeps streaming while storage stays stuck: appends are
      // accepted but never written. The second one's backlog fits; the third
      // pushes it past the ring capacity and the accept-time latch trips.
      pumpSamples(hub, frame, chunkSamples, 42);
      unawaited(
        writer.appendData(hub.snapshotRange(chunkSamples, chunkSamples)),
      );
      expect(writer.hasError, isFalse);
      pumpSamples(hub, frame, 100, 13);
      unawaited(writer.appendData(hub.snapshotRange(2 * chunkSamples, 100)));
      expect(writer.hasError, isTrue);
      expect(writer.writeError, isA<StateError>());

      gate.complete();
      await writer.flush();

      // Only the pre-stall chunk reached the sink; the post-latch slices
      // no-op, so only the first chunk is counted.
      expect(writer.totalSamplesRecorded, chunkSamples);
      expect(sinkCalls, 1);
      expect(saved, hasLength(1));
      expect(saved.single.lengthInBytes, chunkSamples * channels * 4);
    });
  });

  group('LiveSessionWriter ssn origin', () {
    test(
      'latches from the hub packet-counter anchor on first append',
      () async {
        final hub = DataHub();
        final frame = Int32List(channels);
        // The first recorded packet's counter anchors at hub index 0 (the
        // decoder's continuity reset at recording start means no gap
        // injection precedes it).
        hub.notePacketCounter(41230);
        for (int i = 0; i < 50; i++) {
          hub.addSampleFrame(frame);
        }

        final writer = LiveSessionWriter(
          testHeader(),
          sourceRingCapacity: DataHub.maxDataSz,
          chunkSink: (sessionId, chunkIndex, data, gapsJson) async =>
              sessionId ?? 1,
        );
        await writer.appendData(hub.snapshotRange(0, 50));

        // The latch is held until the first chunk flush writes it into the
        // row it creates; the startSession-based test below covers the
        // persisted value.
        expect(writer.ssnOrigin, 41230);
      },
    );

    test(
      'wraps past 0xFFFF (unwrapped) and respects the anchor offset',
      () async {
        final hub = DataHub();
        final frame = Int32List(channels);
        for (int i = 0; i < 100; i++) {
          hub.addSampleFrame(frame);
        }
        // Counter anchored mid-stream: hub index 100 carries 65530.
        hub.notePacketCounter(65530);
        for (int i = 0; i < 50; i++) {
          hub.addSampleFrame(frame);
        }

        final writer = LiveSessionWriter(
          testHeader(),
          sourceRingCapacity: DataHub.maxDataSz,
          chunkSink: (sessionId, chunkIndex, data, gapsJson) async =>
              sessionId ?? 1,
        );
        // The session starts at hub index 120: ssn_origin = 65530 + 20 — above
        // the 16-bit wrap, as the format requires.
        await writer.appendData(hub.snapshotRange(120, 30));
        expect(writer.ssnOrigin, 65550);
      },
    );

    test('is written when the first chunk creates the row, and loads back '
        'with the session', () async {
      final hub = DataHub();
      final frame = Int32List(channels);
      hub.notePacketCounter(41230);
      // Past the 16 KB flush threshold in one append (2100 * 4 ch * 4 B).
      for (int i = 0; i < 2100; i++) {
        hub.addSampleFrame(frame);
      }

      final writer = startFromHub(hub, name: 'ssn');

      // No data yet, so no row: the session row is created by the writer's
      // first chunk flush (no row without data).
      expect(await AppDatabase.instance.incompleteSessions(), isEmpty);

      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));

      var row = (await AppDatabase.instance.sessionById(writer.sessionId!))!;
      expect(row.ssnOrigin, 41230);

      await SessionStorage.finalizeSession(writer: writer);
      row = (await AppDatabase.instance.sessionById(writer.sessionId!))!;
      expect(row.ssnOrigin, 41230);

      final loaded = (await SessionStorage.loadSession(row.id))!;
      expect(loaded.ssnOrigin, 41230);
    });

    test('the board meta is frozen at start and loads back with the '
        'session', () async {
      final hub = DataHub();
      hub.updateBoardCalibration(
        BoardCalibration(
          channels: [
            for (int ch = 0; ch < channels; ch++)
              ChannelBoardCalibration(
                nominals: const ChannelNominals(
                  adcFsrV: 1.2,
                  afeGain: 101,
                  pgaGain: 2,
                  excitationV: 4.53,
                ),
              ),
          ],
          factoryDate: '2026-01-15',
          calTool: 'calibrate.py v3',
          nominals: BoardNominals(
            adcFsrV: 1.2,
            afeGain: 101,
            excitationV: 4.53,
            pgaGains: const [2, 2, 2, 2],
            provenance: const {'exc': 'nominal'},
          ),
        ),
      );
      final frame = Int32List(channels);
      hub.notePacketCounter(0);
      for (int i = 0; i < 1100; i++) {
        hub.addSampleFrame(frame);
      }
      final writer = startFromHub(hub, name: 'meta');

      // No board-meta column before the row exists (no row without data).
      expect(await AppDatabase.instance.incompleteSessions(), isEmpty);

      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));
      await SessionStorage.finalizeSession(writer: writer);

      final row = (await AppDatabase.instance.sessionById(writer.sessionId!))!;
      expect(row.boardMetaJson, isNotNull);
      // The CSV recorded_at was frozen at recording start (before this
      // test's first flush created the row) and parses back to an instant.
      final startedAt = DateTime.now();
      final recordedAt = DateTime.parse(row.recordedAt);
      expect(recordedAt.isAfter(startedAt), isFalse);

      final loaded = (await SessionStorage.loadSession(row.id))!;
      expect(loaded.damage.isEmpty, isTrue);
      final meta = loaded.boardMeta!;
      expect(meta.factoryDate, '2026-01-15');
      expect(meta.calTool, 'calibrate.py v3');
      expect(meta.constantsStatus, BoardDataStatus.ok);
      expect(meta.provenance, {'exc': 'nominal'});
      expect(meta.calDataInvalid, isFalse);
    });
  });

  /// The chunk table must back the writer's accepted-sample count at
  /// finalize: if writes were acknowledged but rows never landed (however
  /// that happens — a storage-layer drop, or a writer-side skip), pretending
  /// all is well would surface later as a truncated session. finalizeSession
  /// must fail loud instead.
  group('finalizeSession consistency check', () {
    test('a dropped chunk makes finalizeSession return an error', () async {
      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      // Two chunks' worth of samples (the flush threshold is ~1024 samples),
      // fed as two appends so the first flushes chunk 0 and the second chunk 1.
      const perAppend = 1100;
      for (int i = 0; i < perAppend * 2; i++) {
        hub.addSampleFrame(frame);
      }

      // A sink that persists chunk 0 (creating the row through the real DB
      // path) but silently drops every later chunk — storage acknowledging
      // writes it never lands.
      final db = AppDatabase.instance;
      final dropping = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: DataHub.maxDataSz,
        chunkSink: (id, chunkIndex, data, gapsJson) async {
          if (chunkIndex == 0) {
            return db.createSessionWithFirstChunk(
              header: testHeader(),
              ssnOrigin: 0,
              gaps: gapsJson,
              data: data,
            );
          }
          return id!; // acknowledge chunks 1+ without writing them
        },
      );
      await dropping.appendData(hub.snapshotRange(0, perAppend));
      await dropping.appendData(hub.snapshotRange(perAppend, perAppend));
      final error = await SessionStorage.finalizeSession(writer: dropping);

      expect(error, isA<StateError>());
      expect(error.toString(), contains('storage layer dropped samples'));
    });

    test('an intact multi-chunk recording finalizes with no error', () async {
      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      // Regression for the skipped-sink bug: the writer latched the session
      // id with `_sessionId ??= await sink(...)`, so after chunk 0 the sink
      // call itself was never evaluated and every later chunk was silently
      // discarded. Two appends of 1100 frames each cross the ~16 KB flush
      // threshold twice, so this fails unless chunks 0 AND 1 are written —
      // a single append would land entirely in chunk 0 and miss the bug.
      const perAppend = 1100;
      const total = 2 * perAppend;
      for (int i = 0; i < total; i++) {
        hub.addSampleFrame(frame);
      }
      final writer = startFromHub(hub, name: 'ok');
      await writer.appendData(hub.snapshotRange(0, perAppend));
      await writer.appendData(hub.snapshotRange(perAppend, perAppend));
      final error = await SessionStorage.finalizeSession(writer: writer);
      expect(error, isNull);
      expect(
        (await AppDatabase.instance.sessionById(
          writer.sessionId!,
        ))!.sampleCount,
        total,
      );
      final loaded = await SessionStorage.loadSession(writer.sessionId!);
      expect(loaded, isNotNull);
      expect(loaded!.sampleCount, total);
      expect(loaded.damage.truncatedAt, isNull);
    });
  });

  group('SessionChunkCodec', () {
    test('pack/decode round-trips frames exactly', () {
      const codec = SessionChunkCodec(channels);
      final values = [
        [1, 2, 3, 4],
        [-5, 6, -7, 8],
        [
          SessionChunkCodec.maxAdcValue,
          SessionChunkCodec.minAdcValue,
          0,
          123456,
        ],
      ];
      final bytes = codec.pack(values.length, (s, ch) => values[s][ch]);
      expect(codec.framesOf(bytes), values.length);
      expect(bytes.lengthInBytes, values.length * channels * 4);

      final decoded = <List<int>>[];
      codec.decode(bytes, (s, ch, raw) {
        while (decoded.length <= s) {
          decoded.add(List.filled(channels, 0));
        }
        decoded[s][ch] = raw;
      });
      expect(decoded, values);
    });

    test('framesOf ignores trailing partial bytes', () {
      const codec = SessionChunkCodec(channels);
      expect(codec.framesOf(Uint8List(0)), 0);
      expect(codec.framesOf(Uint8List(channels * 4 - 1)), 0);
      expect(codec.framesOf(Uint8List(channels * 4)), 1);
      expect(codec.framesOf(Uint8List(channels * 4 + 1)), 1);
    });
  });

  group('session data integrity', () {
    const codec = SessionChunkCodec(channels);

    /// Pro-like test chain; sessions using it convert unless damaged.
    const testNominals = ChannelNominals(
      adcFsrV: 1.2,
      afeGain: 101,
      pgaGain: 1,
      excitationV: 4.53,
    );

    final validCalsJson = jsonEncode([
      for (int ch = 0; ch < channels; ch++)
        ChannelCalibration(
          board: ChannelBoardCalibration(nominals: testNominals),
        ).toJson(),
    ]);

    /// Pack [frames] (per-frame channel values) into one chunk per entry.
    Uint8List packChunk(List<List<int>> frames) =>
        codec.pack(frames.length, (s, ch) => frames[s][ch]);

    /// A completed session row with chunk rows inserted at [chunkIndices]
    /// (default: 0..N-1 contiguous) and the given metadata columns.
    Future<int> makeSessionRow({
      required List<Uint8List> chunks,
      List<int>? chunkIndices,
      String tares = '[0,0,0,0]',
      String? calibrationJson,
      String gaps = '[]',
      int? sampleCount,
      bool complete = true,
      String? boardMetaJson,
    }) async {
      final id = await AppDatabase.instance.createSession(
        name: 'integrity',
        sampleRate: 1000,
        channelCount: channels,
        channelLabels: '["a","b","c","d"]',
        tares: tares,
        calibrationJson: calibrationJson ?? validCalsJson,
        visibleChannels: '[true,true,true,true]',
        displayUnit: 'kgf',
        deviceInfoJson: '{}',
        boardMetaJson: boardMetaJson,
        ssnOrigin: 100,
        gaps: gaps,
      );
      final indices =
          chunkIndices ?? [for (var i = 0; i < chunks.length; i++) i];
      for (var i = 0; i < chunks.length; i++) {
        await AppDatabase.instance.insertChunk(id, indices[i], chunks[i]);
      }
      if (complete) {
        final frames = chunks.fold<int>(0, (acc, c) => acc + codec.framesOf(c));
        await AppDatabase.instance.completeSession(
          id,
          sampleCount: sampleCount ?? frames,
          durationMs: 1,
          gaps: gaps,
        );
      }
      return id;
    }

    test('an intact session loads with no damage flags', () async {
      final id = await makeSessionRow(
        chunks: [
          packChunk([
            [1, 2, 3, 4],
            [5, 6, 7, 8],
          ]),
        ],
      );
      final data = (await SessionStorage.loadSession(id))!;
      expect(data.damage.isEmpty, isTrue);
      expect(data.damage.warningCodes, isEmpty);
      expect(data.sampleCount, 2);
      expect(data.channels[3][1], 8);
      expect(
        resolveUnitAvailability(data.calibrationFor, [0]).boardHasNominals,
        isTrue,
      );
    });

    test(
      'a damaged tare column floors to null without a damage flag',
      () async {
        final id = await makeSessionRow(
          chunks: [
            packChunk([
              [10, 2, 3, 4],
            ]),
          ],
          tares: '[0,0,"bogus",0]',
        );
        final data = (await SessionStorage.loadSession(id))!;
        // Null (no offset) IS the honest floor — a first-class state every
        // viewer renders, so no flag distinguishes damage from never-tared.
        expect(data.tares, everyElement(isNull));
        expect(data.damage.isEmpty, isTrue);
        // Conversion stays available: calibration is intact, and a null tare
        // converts as gross.
        expect(
          resolveUnitAvailability(data.calibrationFor, [0]).boardHasNominals,
          isTrue,
        );
        // The sample data itself is untouched.
        expect(data.channels[0][0], 10);
      },
    );

    test('null tares load; legacy zeroed tares parse as no offset', () async {
      Future<List<double?>> loadTares(String tares) async {
        final id = await makeSessionRow(
          chunks: [
            packChunk([
              [1, 2, 3, 4],
            ]),
          ],
          tares: tares,
        );
        return (await SessionStorage.loadSession(id))!.tares;
      }

      expect(await loadTares('[null,null,null,null]'), everyElement(isNull));
      expect(await loadTares('[10,null,-5,0]'), [10.0, null, -5.0, null]);
    });

    test(
      'a damaged calibration column floors the whole board uniformly',
      () async {
        // One malformed entry: per-entry salvage would produce a mixed board
        // (exactly what the flash parser rejects) — the whole column is damage.
        final badCals = jsonEncode([
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
          ).toJson(),
          {'board': 'junk'},
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
          ).toJson(),
          ChannelCalibration(
            board: ChannelBoardCalibration(nominals: testNominals),
          ).toJson(),
        ]);
        final id = await makeSessionRow(
          chunks: [
            packChunk([
              [1, 2, 3, 4],
            ]),
          ],
          calibrationJson: badCals,
        );
        final data = (await SessionStorage.loadSession(id))!;
        expect(data.damage.calibration, isTrue);
        for (int ch = 0; ch < channels; ch++) {
          expect(data.calibrationFor(ch).board.nominals, isNull);
        }
        expect(
          data.damage.warningCodes,
          contains('session_calibration_damaged'),
        );
        expect(
          resolveUnitAvailability(data.calibrationFor, [0]).boardHasNominals,
          isFalse,
        );
      },
    );

    test('a damaged gaps column loses the dropouts but keeps the data', () async {
      final id = await makeSessionRow(
        chunks: [
          packChunk([
            [1, 2, 3, 4],
          ]),
        ],
        gaps: '[[0,5]] garbage',
      );
      final data = (await SessionStorage.loadSession(id))!;
      expect(data.damage.gapsLost, isTrue);
      expect(data.gaps.isEmpty, isTrue);
      expect(data.damage.warningCodes, contains('session_gaps_lost'));
      // Conversion is NOT forced: the sample stream and calibration are intact.
      expect(
        resolveUnitAvailability(data.calibrationFor, [0]).boardHasNominals,
        isTrue,
      );
    });

    test(
      'a NULL board-meta column loads as an absent block, no flag',
      () async {
        final id = await makeSessionRow(
          chunks: [
            packChunk([
              [1, 2, 3, 4],
            ]),
          ],
        );
        final data = (await SessionStorage.loadSession(id))!;
        expect(data.boardMeta, isNull);
        expect(data.damage.isEmpty, isTrue);
      },
    );

    test('a board-meta column round-trips its frozen provenance', () async {
      const meta = SessionBoardMeta(
        factoryDate: '2026-01-15',
        calBoardId: 'cal-01',
        calTool: 'calibrate.py v3',
        calOrigin: 'factory',
        calTempsC: (dut: 23.1, calBoard: 22.8),
        calAdcGains: [1, 2, 4, 8],
        calDataInvalid: true,
        constantsStatus: BoardDataStatus.invalid,
        constantsDetail: 'missing afe_gain',
        provenance: {'exc': 'nominal'},
      );
      final id = await makeSessionRow(
        chunks: [
          packChunk([
            [1, 2, 3, 4],
          ]),
        ],
        boardMetaJson: jsonEncode(meta.toJson()),
      );
      final data = (await SessionStorage.loadSession(id))!;
      expect(data.damage.isEmpty, isTrue);
      final loaded = data.boardMeta!;
      expect(loaded.factoryDate, '2026-01-15');
      expect(loaded.calBoardId, 'cal-01');
      expect(loaded.calTool, 'calibrate.py v3');
      expect(loaded.calOrigin, 'factory');
      expect(loaded.calTempsC, (dut: 23.1, calBoard: 22.8));
      expect(loaded.calAdcGains, [1.0, 2.0, 4.0, 8.0]);
      expect(loaded.calDataInvalid, isTrue);
      expect(loaded.constantsStatus, BoardDataStatus.invalid);
      expect(loaded.constantsDetail, 'missing afe_gain');
      expect(loaded.provenance, {'exc': 'nominal'});
    });

    test(
      'a damaged board-meta column floors to absent and flags the loss',
      () async {
        final id = await makeSessionRow(
          chunks: [
            packChunk([
              [1, 2, 3, 4],
            ]),
          ],
          boardMetaJson: '{"constants_status":"bogus"}',
        );
        final data = (await SessionStorage.loadSession(id))!;
        expect(data.boardMeta, isNull);
        expect(data.damage.boardMetaLost, isTrue);
        expect(data.damage.isEmpty, isFalse);
        expect(
          data.damage.warningCodes,
          contains('session_board_meta_damaged'),
        );
        // The operative calibration is a separate column, still intact.
        expect(
          resolveUnitAvailability(data.calibrationFor, [0]).boardHasNominals,
          isTrue,
        );
      },
    );

    test('a missing middle chunk truncates instead of splicing', () async {
      final chunk0 = packChunk([
        [1, 1, 1, 1],
        [2, 2, 2, 2],
      ]);
      final chunk1 = packChunk([
        [3, 3, 3, 3],
      ]);
      // Index 2 is missing; index 3's samples have no knowable position.
      final chunk3 = packChunk([
        [9, 9, 9, 9],
        [9, 9, 9, 9],
      ]);
      final id = await makeSessionRow(
        chunks: [chunk0, chunk1, chunk3],
        chunkIndices: [0, 1, 3],
        sampleCount: 5,
        gaps: '[[2,5]]',
      );
      final data = (await SessionStorage.loadSession(id))!;
      expect(data.damage.truncatedAt, 3);
      expect(data.sampleCount, 3);
      // The verified prefix is intact; nothing from chunk 3 spliced in.
      expect(data.channels[0].toList(), [1, 2, 3]);
      // The gap range is clamped to the truncation point.
      expect(data.gaps.contains(2), isTrue);
      expect(data.gaps.contains(4), isFalse);
      expect(
        data.damage.warningCodes,
        contains('session_truncated_at_sample:3'),
      );
    });

    test('a misaligned blob truncates at that chunk', () async {
      final good = packChunk([
        [1, 1, 1, 1],
        [2, 2, 2, 2],
      ]);
      final bad = Uint8List(channels * 4 + 3); // 3 trailing garbage bytes
      final id = await makeSessionRow(chunks: [good, bad], sampleCount: 2);
      final data = (await SessionStorage.loadSession(id))!;
      expect(data.damage.truncatedAt, 2);
      expect(data.sampleCount, 2);
    });

    test(
      'frame-count overflow and underflow truncate to the smaller claim',
      () async {
        final chunks = [
          packChunk([
            [1, 1, 1, 1],
            [2, 2, 2, 2],
            [3, 3, 3, 3],
            [4, 4, 4, 4],
          ]),
        ];
        // Metadata claims fewer than the chunks hold.
        final over = await makeSessionRow(chunks: chunks, sampleCount: 3);
        var data = (await SessionStorage.loadSession(over))!;
        expect(data.sampleCount, 3);
        expect(data.damage.truncatedAt, 3);
        // Metadata claims more than the chunks hold.
        final under = await makeSessionRow(chunks: chunks, sampleCount: 9);
        data = (await SessionStorage.loadSession(under))!;
        expect(data.sampleCount, 4);
        expect(data.damage.truncatedAt, 4);
      },
    );

    test('damage at chunk 0 has no honest view and throws', () async {
      // Hole at index 0.
      var id = await makeSessionRow(
        chunks: [
          packChunk([
            [1, 1, 1, 1],
          ]),
        ],
        chunkIndices: [1],
        sampleCount: 1,
      );
      await expectLater(SessionStorage.loadSession(id), throwsStateError);
      // Misaligned first blob.
      id = await makeSessionRow(chunks: [Uint8List(3)], sampleCount: 0);
      await expectLater(SessionStorage.loadSession(id), throwsStateError);
    });

    test(
      'collision-free zero-frame chunks still load as an empty session',
      () async {
        final id = await makeSessionRow(chunks: [Uint8List(0)], sampleCount: 0);
        final data = (await SessionStorage.loadSession(id))!;
        expect(data.sampleCount, 0);
        expect(data.damage.isEmpty, isTrue);
      },
    );

    test(
      'recovery completes the verified prefix of a damaged recording',
      () async {
        final good = packChunk([
          [1, 1, 1, 1],
          [2, 2, 2, 2],
        ]);
        final bad = Uint8List(7); // misaligned trailing chunk
        final id = await makeSessionRow(
          chunks: [good, bad],
          complete: false,
          gaps: '[[0,3]]',
        );

        await SessionStorage.recoverIncompleteSessions();

        final row = (await AppDatabase.instance.sessionById(id))!;
        expect(row.isCompleted, isTrue);
        // The misaligned chunk's frames are not counted.
        expect(row.sampleCount, 2);
        // Gaps are clamped to the verified prefix.
        expect(row.gaps, '[[0,2]]');
        // The damaged chunk stays on disk, so the load re-flags the damage.
        final data = (await SessionStorage.loadSession(id))!;
        expect(data.damage.truncatedAt, 2);
      },
    );
  });

  group('crash recovery', () {
    test('gaps persisted on flush survive recoverIncompleteSessions', () async {
      // A stream with a dropped range: 2100 real samples, a 20-sample gap,
      // 100 more real samples — past the 16 KB flush threshold.
      final hub = DataHub();
      final frame = Int32List(channels);
      void pump(int count, int value) {
        frame.fillRange(0, channels, value);
        for (int i = 0; i < count; i++) {
          hub.addSampleFrame(frame);
        }
      }

      hub.notePacketCounter(41230);
      pump(2100, 7);
      hub.addDroppedFrames(20);
      pump(100, 9);

      final writer = startFromHub(hub, name: 'crash me');
      // The single append crosses the flush threshold, so the chunk insert
      // AND the incremental gaps update land in the DB.
      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));

      final beforeCrash = await AppDatabase.instance.sessionById(
        writer.sessionId!,
      );
      expect(beforeCrash!.gaps, '[[2100,2120]]');
      expect(beforeCrash.ssnOrigin, 41230);

      // Simulate the crash: recover without finalizeSession ever running.
      await SessionStorage.recoverIncompleteSessions();

      final row = await AppDatabase.instance.sessionById(writer.sessionId!);
      expect(row, isNotNull);
      expect(row!.isCompleted, isTrue);
      expect(row.sampleCount, hub.totalSamples);
      // Recovery rebuilt the aggregates but preserved the persisted gaps
      // and the persisted ssn origin.
      expect(row.gaps, '[[2100,2120]]');
      expect(row.ssnOrigin, 41230);

      final loaded = await SessionStorage.loadSession(row.id);
      expect(loaded, isNotNull);
      expect(loaded!.gaps.contains(2100), isTrue);
      expect(loaded.gaps.contains(2119), isTrue);
      expect(loaded.gaps.contains(2120), isFalse);
      expect(loaded.ssnOrigin, 41230);
    });

    test('a session with only empty chunks completes as empty', () async {
      // A chunk row exists, but it holds no complete frame (0 bytes), so
      // the recovered frame count is 0.
      final sessionId = await AppDatabase.instance.createSession(
        name: 'empty chunks',
        sampleRate: 1000,
        channelCount: channels,
        channelLabels: '["a","b","c","d"]',
        tares: '[0,0,0,0]',
        calibrationJson: '[]',
        visibleChannels: '[true,true,true,true]',
        displayUnit: 'kgf',
        deviceInfoJson: '{}',
        boardMetaJson: null,
        ssnOrigin: 0,
      );
      await AppDatabase.instance.insertChunk(sessionId, 0, Uint8List(0));

      await SessionStorage.recoverIncompleteSessions();

      final row = await AppDatabase.instance.sessionById(sessionId);
      expect(row, isNotNull);
      expect(row!.isCompleted, isTrue);
      expect(row.sampleCount, 0);
      expect(row.durationMs, 0);
    });
  });

  group('session calibration snapshot', () {
    test(
      'playback converts through the calibration recorded with the session',
      () async {
        // Pro-like test chain, reproducing the app's former compiled
        // constants.
        const testNominals = ChannelNominals(
          adcFsrV: 1.2,
          afeGain: 101,
          pgaGain: 1,
          excitationV: 4.53,
        );
        final hub = DataHub();
        const nominalLadder = <double>[10000, 10, 10, 10, 10, 10000];
        final sp = ladderSetpointsMvV(nominalLadder);
        // Every channel measures at half the nominal span (calibration is
        // board-uniform — a mixed board is invalid flash, rejected at parse).
        hub.updateBoardCalibration(
          BoardCalibration(
            channels: [
              for (int i = 0; i < channels; ++i)
                ChannelBoardCalibration(
                  resistors: nominalLadder,
                  readings: [
                    for (final d in sp)
                      500 + 0.5 * testNominals.countsPerMvV * d,
                  ],
                  nominals: testNominals,
                ),
            ],
          ),
        );
        hub.updateLoadCells([
          LoadCellProfile(name: 'Ref', capacityKg: 100, sensitivityMvV: 2.02),
          null,
          null,
          null,
        ]);

        final frame = Int32List(channels)..fillRange(0, channels, 1000);
        for (int i = 0; i < 10; i++) {
          hub.addSampleFrame(frame);
        }

        final writer = startFromHub(hub, name: 'cal');
        await writer.appendData(hub.snapshotRange(0, hub.totalSamples));
        await SessionStorage.finalizeSession(writer: writer);

        final row = await AppDatabase.instance.sessionById(writer.sessionId!);
        final loaded = (await SessionStorage.loadSession(row!.id))!;

        // Board snapshot: ch0 at 0.5x nominal sensitivity.
        expect(
          loaded.calibrationFor(0).board.sensitivityCountsPerMvV,
          closeTo(0.5 * testNominals.countsPerMvV, 1e-3),
        );
        expect(loaded.calibrationFor(0).board.isFactoryCalibrated, isTrue);
        // The resolved nominals rode along in the snapshot.
        expect(loaded.calibrationFor(0).board.nominals, isNotNull);
        expect(
          loaded.calibrationFor(0).board.nominals!.countsPerMvV,
          closeTo(testNominals.countsPerMvV, 1e-12),
        );
        // Load cell snapshot round-trips with its exact sensitivity.
        final cell = loaded.calibrationFor(0).loadCell!;
        expect(cell.name, 'Ref');
        expect(cell.sensitivityMvV, closeTo(2.02, 1e-12));
        // End-to-end: kgf converts through the stored board AND stored cell.
        final kgf = ChannelConverter(
          loaded.calibrationFor(0),
          0,
        ).netMap(DisplayUnit.kgf)!;
        expect(
          kgf(1000),
          closeTo(
            1000 / (0.5 * testNominals.countsPerMvV) * (100 / 2.02),
            1e-9,
          ),
        );
        // ch1 had no load cell assigned at recording time.
        expect(
          ChannelConverter(loaded.calibrationFor(1), 0).netMap(DisplayUnit.kgf),
          isNull,
        );
      },
    );
  });
}
