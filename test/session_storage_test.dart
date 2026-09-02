import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/channel_converter.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/session_catalog.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_data.dart';
import 'package:dynamite_app/services/session_files_io.dart';
import 'package:dynamite_app/services/session_journal.dart';
import 'package:dynamite_app/services/session_storage.dart';
import 'package:dynamite_app/services/session_store.dart';
import 'package:dynamite_app/services/session_store_backend.dart';

/// Storage-side session tests: the live writer (snapshot latch, backpressure,
/// ssn origin), finalize's ack-length check and interrupted verdicts, and
/// the file store's listing/damage/edit verdicts. Every test runs against
/// the real dart:io backend pointed at a temp sessions root.
void main() {
  const int channels = kAdcChannelCount;

  late Directory tmp;
  late SessionStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_store_test');
    SessionStore.instance = store = SessionStore.over(
      IoSessionFilesBackend('${tmp.path}/sessions'),
    );
  });
  tearDown(() {
    SessionStore.instance = null;
    tmp.deleteSync(recursive: true);
  });

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

  /// A writer-side header without going through the hub (the sink-seam
  /// tests above the store only need its fields).
  SessionHeader testHeader() => (
    name: '',
    sampleRate: 1000,
    channelCount: channels,
    channelLabels: const ['a', 'b', 'c', 'd'],
    tares: List<double?>.filled(channels, null),
    calibration: nominalCals(),
    visibleChannels: const [true, true, true, true],
    displayUnit: 'kgf',
    deviceInfo: const {},
    boardMeta: null,
    recordedAt: '2026-07-29T14:05:32.000Z',
  );

  SessionMeta testMeta({String name = 'test'}) => SessionMeta(
    name: name,
    sampleRate: 1000,
    channelCount: channels,
    channelLabels: const ['a', 'b', 'c', 'd'],
    tares: List<double?>.filled(channels, null),
    calibration: nominalCals(),
    visibleChannels: const [true, true, true, true],
    displayUnit: 'kgf',
    deviceInfo: const {},
    boardMeta: null,
    recordedAt: '2026-07-29T14:05:32.000Z',
    ssnOrigin: 100,
  );

  SessionCatalog readyCatalog() => switch (store.catalog.value) {
    SessionCatalogReady(:final catalog) => catalog,
    final state => throw StateError('Expected ready catalog, got $state'),
  };

  Future<SessionCatalog> catalog() async {
    await store.refreshCatalog();
    return readyCatalog();
  }

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
      SessionMeta? stampedMeta;
      final writer = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: DataHub.maxDataSz,
        sinkFactory: (meta, firstData) async {
          stampedMeta = meta;
          saved.add(firstData);
          return _CollectSink('test-id');
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

      // The first packet's data raw holds the call-time values, byte for
      // byte, and the journal line 1 was stamped with the latched origin.
      expect(saved, hasLength(1));
      expect(stampedMeta!.ssnOrigin, 0);
      expect(stampedMeta!.name, testHeader().name);
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
      // packets of backlog instead of a real 10-minute ring.
      const ringCapacity = 4096;
      final writer = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: ringCapacity,
        sinkFactory: (meta, firstData) async {
          sinkCalls++;
          if (!entered.isCompleted) entered.complete();
          await gate.future; // wedge the first write until released
          saved.add(firstData);
          return _CollectSink('test-id');
        },
      );
      final hub = DataHub();
      final frame = Int32List(channels);

      // One packet in flight, blocked inside the factory.
      const packetSamples = 2048;
      pumpSamples(hub, frame, packetSamples, 7);
      unawaited(writer.appendData(hub.snapshotRange(0, packetSamples)));
      await entered.future; // the queue is now stuck behind the gated write

      // The producer keeps streaming while storage stays stuck: appends are
      // accepted but never written. The second one's backlog fits; the third
      // pushes it past the ring capacity and the accept-time latch trips.
      pumpSamples(hub, frame, packetSamples, 42);
      unawaited(
        writer.appendData(hub.snapshotRange(packetSamples, packetSamples)),
      );
      expect(writer.hasError, isFalse);
      pumpSamples(hub, frame, 100, 13);
      unawaited(writer.appendData(hub.snapshotRange(2 * packetSamples, 100)));
      expect(writer.hasError, isTrue);
      expect(writer.writeError, isA<StateError>());

      gate.complete();
      await writer.flush();

      // Only the pre-stall packet reached the store; the post-latch slices
      // no-op, so only the first packet is counted.
      expect(writer.totalSamplesRecorded, packetSamples);
      expect(sinkCalls, 1);
      expect(saved, hasLength(1));
      expect(saved.single.lengthInBytes, packetSamples * channels * 4);
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
          sinkFactory: (meta, firstData) async => _CollectSink('test-id'),
        );
        await writer.appendData(hub.snapshotRange(0, 50));

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
          sinkFactory: (meta, firstData) async => _CollectSink('test-id'),
        );
        // The session starts at hub index 120: ssn_origin = 65530 + 20 —
        // above the 16-bit wrap, as the format requires.
        await writer.appendData(hub.snapshotRange(120, 30));
        expect(writer.ssnOrigin, 65550);
      },
    );

    test('is stamped into the journal by the first packet and loads back '
        'with the session', () async {
      final hub = DataHub();
      final frame = Int32List(channels);
      hub.notePacketCounter(41230);
      for (int i = 0; i < 2100; i++) {
        hub.addSampleFrame(frame);
      }

      final writer = startFromHub(hub, name: 'ssn');

      // No data yet, so no directory: the session is created by the writer's
      // first packet (no artifact without data).
      expect((await catalog()).sessions, isEmpty);

      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));
      await SessionStorage.finalizeSession(writer: writer);

      final summary = (await catalog()).session(writer.sessionId!)!;
      expect(summary.sampleRate, 1000);
      final loaded = await store.loadSession(summary.id);
      expect(loaded.ssnOrigin, 41230);
    });
  });

  /// The last append's ack length must back the writer's accepted-sample
  /// count at finalize: if writes were acknowledged but bytes never landed,
  /// pretending all is well would surface later as a truncated session.
  /// finalizeSession must fail loud instead — and leave no marker behind, so
  /// the truncated session can never list as complete.
  group('finalizeSession consistency check', () {
    test('a silently dropping sink makes finalizeSession return an error and '
        'leaves the session interrupted', () async {
      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      const perAppend = 1100;
      for (int i = 0; i < perAppend * 2; i++) {
        hub.addSampleFrame(frame);
      }

      // The first packet creates a real session through the store, but the
      // sink acknowledges every later append without writing a byte.
      final dropping = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: DataHub.maxDataSz,
        sinkFactory: (meta, firstData) async {
          final real = await store.createDataSink(
            meta: meta,
            firstData: firstData,
          );
          final fakeLength = firstData.lengthInBytes;
          return _WrapSink(real, onAppend: (bytes) async => fakeLength);
        },
      );
      await dropping.appendData(hub.snapshotRange(0, perAppend));
      await dropping.appendData(hub.snapshotRange(perAppend, perAppend));
      final error = await SessionStorage.finalizeSession(writer: dropping);

      expect(error, isA<StateError>());
      expect(error.toString(), contains('storage layer dropped samples'));

      // The error is transient (one toast at stop time); the interrupted
      // verdict is permanent: no marker, no "complete" listing — ever.
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted.single.id, dropping.sessionId);
      expect(listed.damaged, isEmpty);
    });

    test('a throwing close folds into the returned error and the session '
        'lists as interrupted', () async {
      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      for (int i = 0; i < 1100; i++) {
        hub.addSampleFrame(frame);
      }

      final closeBoom = StateError('close failed');
      final writer = LiveSessionWriter(
        testHeader(),
        sourceRingCapacity: DataHub.maxDataSz,
        sinkFactory: (meta, firstData) async {
          final real = await store.createDataSink(
            meta: meta,
            firstData: firstData,
          );
          return _WrapSink(
            real,
            onAppend: real.append,
            // The handle still goes away (test teardown must delete the
            // temp root); only the close's completion reports failure.
            onClose: () async {
              await real.close();
              throw closeBoom;
            },
          );
        },
      );
      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));
      final error = await SessionStorage.finalizeSession(writer: writer);

      // Any latched failure vetoes the marker, close included: the store
      // cannot vouch for the session, so it lists as interrupted with its
      // (fully written) bytes loading and exporting like a complete one.
      expect(error, same(closeBoom));
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted.single.id, writer.sessionId);
      expect(listed.damaged, isEmpty);
    });

    test('a failing marker write folds into the returned error and the '
        'session lists as interrupted immediately', () async {
      final failing = _FaultBackend(
        IoSessionFilesBackend('${tmp.path}/sessions'),
      );
      SessionStore.instance = store = SessionStore.over(failing);

      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
      for (int i = 0; i < 1100; i++) {
        hub.addSampleFrame(frame);
      }
      final writer = startFromHub(hub, name: 'marker fails');
      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));

      failing.failTouchFinal = true;
      final error = await SessionStorage.finalizeSession(writer: writer);

      // The marker error surfaces through the same returned-error channel
      // as every other finalize failure (it must not throw), ...
      expect(error, isA<StateError>());
      expect(error.toString(), contains('marker write failed'));

      // ... and with no marker the dir is by definition an interrupted
      // session, spliced into the published catalog NOW. readyCatalog()
      // reads the catalog as-is — no refresh — so this fails if finalize
      // left the session hidden until the next startup's scan.
      final listed = readyCatalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted.single.id, writer.sessionId);
      expect(listed.damaged, isEmpty);
      expect(await failing.isFinalized(writer.sessionId!), isFalse);
    });

    test('an intact multi-packet recording finalizes with no error', () async {
      final hub = DataHub();
      hub.notePacketCounter(0);
      final frame = Int32List(channels);
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

      final loaded = await store.loadSession(writer.sessionId!);
      expect(loaded.sampleCount, total);
      final summaries = (await catalog()).sessions;
      expect(summaries, hasLength(1));
    });
  });

  group('interrupted sessions', () {
    test('a crashed recording lists as interrupted with salvageable bytes, '
        'never promoted', () async {
      // A stream with a dropped range: 2100 real samples, a 20-sample gap,
      // 100 more real samples.
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
      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));

      // While the store still owns the in-flight recording, the dir is
      // invisible: not listed, not interrupted, not damaged.
      expect((await catalog()).sessions, isEmpty);
      expect((await catalog()).interrupted, isEmpty);
      expect((await catalog()).damaged, isEmpty);

      // Simulate the crash: release the data handle the way a process
      // death would (so teardown can delete the temp root), and a fresh
      // store over the same root knows nothing of the in-flight recorder.
      await writer.closeSink();
      SessionStore.instance = store = SessionStore.over(
        IoSessionFilesBackend('${tmp.path}/sessions'),
      );

      // No finalize ever ran, so no marker ever got written: the
      // recording lists as interrupted — permanently; nothing promotes it.
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.damaged, isEmpty);
      expect(listed.interrupted.single.id, writer.sessionId);

      // It loads and decodes exactly like a complete session: in-band
      // gaps and the ssn origin surface through the normal load path.
      final loaded = await store.loadSession(writer.sessionId!);
      expect(loaded.sampleCount, hub.totalSamples);
      expect(loaded.ssnOrigin, 41230);
      expect(loaded.gaps.contains(2100), isTrue);
      expect(loaded.gaps.contains(2119), isTrue);
      expect(loaded.gaps.contains(2120), isFalse);
      // Held values across the gap: the last real frame's values.
      expect(loaded.channels[0][2100], 7);
      expect(loaded.channels[0][2119], 7);
      expect(loaded.channels[0][2120], 9);

      // An interrupted session is never promoted: a re-scan re-derives the
      // same verdict, and no marker appears.
      await store.refreshCatalog();
      expect((await catalog()).interrupted.single.id, writer.sessionId);
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

        final loaded = await store.loadSession(writer.sessionId!);

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
      for (int i = 0; i < 10; i++) {
        hub.addSampleFrame(frame);
      }
      final writer = startFromHub(hub, name: 'meta');
      await writer.appendData(hub.snapshotRange(0, hub.totalSamples));
      await SessionStorage.finalizeSession(writer: writer);

      final loaded = await store.loadSession(writer.sessionId!);
      final m = loaded.boardMeta!;
      expect(m.factoryDate, '2026-01-15');
      expect(m.calTool, 'calibrate.py v3');
      expect(m.constantsStatus, BoardDataStatus.ok);
      expect(m.provenance, {'exc': 'nominal'});
      expect(m.calDataInvalid, isFalse);
    });
  });

  group('file store listing', () {
    late IoSessionFilesBackend backend;

    setUp(() {
      backend = IoSessionFilesBackend('${tmp.path}/sessions');
    });

    const codec = SessionChunkCodec(kAdcChannelCount);

    /// Seed a session directory directly (store-writing tests skip the
    /// writer pipeline): [frames] real values, [gapRanges] sentinel-filled
    /// slice-relative spans, optional journal bytes override (damage
    /// shapes), completion marker per [finalized].
    Future<String> seedSession(
      String id, {
      SessionMeta? m,
      Uint8List? journalOverride,
      List<List<int>> frames = const [
        [1, 1, 1, 1],
        [2, 2, 2, 2],
      ],
      List<(int, int)> gapRanges = const [],
      bool finalized = true,
    }) async {
      final meta = m ?? testMeta();
      final data = codec.pack(frames.length, (s, ch) => frames[s][ch]);
      codec.fillGapSentinels(data, gapRanges);
      final sink = await backend.createSession(
        id,
        journalOverride ?? encodeSessionMeta(meta),
        data,
      );
      await sink.close();
      if (finalized) await backend.touchFinal(id);
      return id;
    }

    test('finalized sessions list newest-first with derived counts', () async {
      await seedSession('2026-08-28T14-30-12-aaaa');
      await seedSession('2026-08-28T14-30-12-zzzz'); // same-second tie
      await seedSession('2026-08-29T09-00-00-bbbb');

      final summaries = (await catalog()).sessions;
      expect(summaries.map((s) => s.id), [
        '2026-08-29T09-00-00-bbbb',
        '2026-08-28T14-30-12-zzzz',
        '2026-08-28T14-30-12-aaaa',
      ]);
      // Derived, not stored: two frames at 1000 Hz.
      expect(summaries.first.durationMs, 2);
      expect(summaries.first.createdAt, DateTime(2026, 8, 29, 9, 0, 0));
      expect(summaries.first.channelLabels, ['a', 'b', 'c', 'd']);
      expect(summaries.first.deviceInfoJson, '{}');

      final sizes = (await catalog()).byteSizes;
      expect(sizes['2026-08-29T09-00-00-bbbb'], 2 * kAdcChannelCount * 4);
    });

    test('finalization publishes its catalog before completing', () async {
      const id = '2026-08-29T09-00-00-race';
      await catalog();
      await seedSession(id, finalized: false);
      expect(readyCatalog().session(id), isNull);

      await store.touchFinal(id);

      expect(readyCatalog().session(id), isNotNull);
    });

    test(
      'concurrent edits are serialized against the latest journal',
      () async {
        const id = '2026-08-29T09-00-00-edit';
        await seedSession(id);

        await Future.wait([
          store.editSession(
            id,
            (current) => SessionEdit(
              name: 'renamed',
              notes: current.notes,
              visibleChannels: current.visibleChannels,
            ),
          ),
          store.editSession(
            id,
            (current) => SessionEdit(
              name: current.name,
              notes: 'new notes',
              visibleChannels: current.visibleChannels,
            ),
          ),
        ]);

        final current = readyCatalog();
        expect(current.session(id)!.name, 'renamed');
        expect(current.session(id)!.notes, 'new notes');
      },
    );

    test('a catalog read failure is terminal', () async {
      final failing = _FaultBackend(backend)..failListings = true;
      SessionStore.instance = store = SessionStore.over(failing);

      await expectLater(
        store.ensureCatalogLoaded(),
        throwsA(isA<StateError>()),
      );
      expect(store.catalog.value, isA<SessionCatalogFailed>());

      failing.failListings = false;
      await expectLater(
        store.createDataSink(
          meta: testMeta(),
          firstData: codec.pack(1, (sample, channel) => 1),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await backend.listDirIds(), isEmpty);
    });

    test('a one-shot read failure is retried, not terminal', () async {
      await seedSession('2026-08-29T09-00-00-once');
      final failing = _FaultBackend(backend)..failNextListings = 1;
      SessionStore.instance = store = SessionStore.over(failing);

      await store.ensureCatalogLoaded();

      expect(store.catalog.value, isA<SessionCatalogReady>());
      expect(readyCatalog().session('2026-08-29T09-00-00-once'), isNotNull);
    });

    test('a classify failure on a delta falls back to a full rescan', () async {
      const id = '2026-08-29T09-00-00-delt';
      final failing = _FaultBackend(backend);
      SessionStore.instance = store = SessionStore.over(failing);
      await seedSession(id, finalized: false);
      await store.ensureCatalogLoaded();

      // The finalize lands on disk; its catalog-delta classification
      // fails once. The full rescan re-derives the same verdict — the
      // op completes and the session lists.
      failing.failNextJournalReads = 1;
      await store.touchFinal(id);

      expect(store.catalog.value, isA<SessionCatalogReady>());
      expect(readyCatalog().session(id), isNotNull);
    });

    test('a delta failure with a failing rescan is terminal', () async {
      const id = '2026-08-29T09-00-00-term';
      final failing = _FaultBackend(backend);
      SessionStore.instance = store = SessionStore.over(failing);
      await seedSession(id, finalized: false);
      await store.ensureCatalogLoaded();

      // Enough faults to survive the delta's classify AND the rescan's
      // own retry: the catalog can only fail.
      failing.failNextJournalReads = 10;
      failing.failNextListings = 10;
      await expectLater(store.touchFinal(id), throwsStateError);
      expect(store.catalog.value, isA<SessionCatalogFailed>());
    });

    test('an unmarked session (no final) lists as interrupted', () async {
      await seedSession('2026-08-28T14-30-12-aaaa', finalized: false);
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted.single.id, '2026-08-28T14-30-12-aaaa');
      expect(listed.damaged, isEmpty);
    });

    test('edits on an interrupted session work and never promote it', () async {
      await seedSession('2026-08-28T14-30-12-eeee', finalized: false);
      expect(
        (await catalog()).interrupted.single.id,
        '2026-08-28T14-30-12-eeee',
      );

      await store.editSession(
        '2026-08-28T14-30-12-eeee',
        (current) => SessionEdit(
          name: 'saved from the crash',
          notes: current.notes,
          visibleChannels: current.visibleChannels,
        ),
      );

      // The rename lands in the summary; the verdict stays interrupted —
      // an edit line is not a completion marker.
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted.single.name, 'saved from the crash');
      expect(await backend.isFinalized('2026-08-28T14-30-12-eeee'), isFalse);

      final loaded = await store.loadSession('2026-08-28T14-30-12-eeee');
      expect(loaded.sampleCount, 2);
    });

    test('an in-flight session (live id) is invisible until aborted', () async {
      // While the store's own writer owns the dir, a listing must not
      // mistake the unmarked session for an interrupted one.
      final sink = await store.createDataSink(
        meta: testMeta(),
        firstData: codec.pack(2, (s, ch) => 42),
      );
      final listed = await catalog();
      expect(listed.sessions, isEmpty);
      expect(listed.interrupted, isEmpty);
      expect(listed.damaged, isEmpty);
      await sink.close();

      // A failed finalize aborts: the interrupted session splices into
      // the published catalog immediately.
      await store.abortSession(sink.id);
      final aborted = readyCatalog();
      expect(aborted.sessions, isEmpty);
      expect(aborted.interrupted.single.id, sink.id);
      expect(aborted.damaged, isEmpty);
    });

    test('a torn header is a damaged entry with both raw exports', () async {
      const codec = SessionChunkCodec(kAdcChannelCount);
      final junk = Uint8List.fromList('{ not json\n'.codeUnits);
      final data = codec.pack(2, (s, ch) => 42);
      final sink = await backend.createSession(
        '2026-08-28T14-30-12-dead',
        junk,
        data,
      );
      await sink.close();

      final damaged = (await catalog()).damaged;
      expect(damaged, hasLength(1));
      expect(damaged.single.id, '2026-08-28T14-30-12-dead');
      expect(damaged.single.hasData, isTrue);
      expect(damaged.single.hasMeta, isTrue);
      expect(damaged.single.reason, contains('metadata unreadable'));

      // The exports hand back the surviving bytes verbatim.
      expect(await store.rawDataBytes(damaged.single.id), data);
      expect(await store.rawJournalBytes(damaged.single.id), junk);
      // Nothing repairs, deletes or finalizes it automatically — a re-scan
      // re-derives the same damaged verdict, marker or not.
      await store.refreshCatalog();
      expect((await catalog()).damaged, hasLength(1));
      expect(await backend.isFinalized(damaged.single.id), isFalse);
    });

    test(
      'a header without data is a damaged entry (crash-at-create)',
      () async {
        const codec = SessionChunkCodec(kAdcChannelCount);
        final sink = await backend.createSession(
          '2026-08-28T14-30-12-0dd0',
          encodeSessionMeta(testMeta()),
          Uint8List(0),
        );
        await sink.close();

        final damaged = (await catalog()).damaged;
        expect(damaged, hasLength(1));
        expect(damaged.single.hasData, isFalse);
        expect(damaged.single.hasMeta, isTrue);
        expect(damaged.single.reason, contains('never produced data'));
        expect(codec.framesOf(Uint8List(0)), 0);

        // The crash-at-create artifact is not the interrupted kind (no
        // frames ever landed): it stays a damaged entry, never quietly
        // finalized into the list.
        await store.refreshCatalog();
        expect(await backend.isFinalized('2026-08-28T14-30-12-0dd0'), isFalse);
        expect((await catalog()).damaged, hasLength(1));
        expect((await catalog()).sessions, isEmpty);
      },
    );

    test(
      'a torn first-packet create is published as damaged, not hidden',
      () async {
        final failing = _FaultBackend(backend)..failCreateAfterJournal = true;
        SessionStore.instance = store = SessionStore.over(failing);
        await store.ensureCatalogLoaded();

        await expectLater(
          store.createDataSink(
            meta: testMeta(),
            firstData: codec.pack(1, (sample, channel) => 1),
          ),
          throwsStateError,
        );

        // The torn directory (journal, no data) lists as damaged
        // immediately — the next startup's scan is not the first to see it,
        // and the catalog did not stay Ready as if storage were fine.
        final damaged = readyCatalog().damaged;
        expect(damaged, hasLength(1));
        expect(damaged.single.hasMeta, isTrue);
        expect(damaged.single.hasData, isFalse);
        expect(damaged.single.reason, contains('never produced data'));
      },
    );

    test(
      'createSession refuses an id whose directory already exists',
      () async {
        await seedSession('2026-08-28T14-30-12-coll');
        await expectLater(
          backend.createSession(
            '2026-08-28T14-30-12-coll',
            encodeSessionMeta(testMeta()),
            codec.pack(1, (s, ch) => 1),
          ),
          throwsStateError,
        );
      },
    );

    test(
      'every append ack means the bytes are on disk (flush per packet)',
      () async {
        const id = '2026-08-28T14-30-12-flus';
        final packet1 = codec.pack(3, (s, ch) => s * 10 + ch);
        final packet2 = codec.pack(2, (s, ch) => 100 + s);
        final sink = await backend.createSession(
          id,
          encodeSessionMeta(testMeta()),
          packet1,
        );
        final dataFile = File('${tmp.path}/sessions/$id/data.raw');

        // Reading the file off disk BEFORE close must already see packet 1:
        // the ack's durability promise covers the in-process handle, and a
        // crash the next instant loses at most the un-acked packet.
        expect(await dataFile.readAsBytes(), packet1);
        await sink.append(packet2);
        expect(await dataFile.readAsBytes(), [...packet1, ...packet2]);
        await sink.close();
      },
    );

    test('a torn data.raw tail is damage, not a truncated load', () async {
      const id = '2026-08-28T14-30-12-tail';
      await seedSession(
        id,
        frames: const [
          [3, 3, 3, 3],
          [7, 7, 7, 7],
        ],
      );
      // Crash mid-append: six stray bytes — not enough to complete a frame.
      final handle = await File(
        '${tmp.path}/sessions/$id/data.raw',
      ).open(mode: FileMode.append);
      await handle.writeFrom(Uint8List(6));
      await handle.close();

      // The session lists as damaged, never as a silently shortened
      // healthy one, and it cannot be loaded or exported normally.
      final damaged = (await catalog()).damaged;
      expect(damaged, hasLength(1));
      expect(damaged.single.id, id);
      expect(damaged.single.reason, contains('mid-frame'));
      await expectLater(store.loadSession(id), throwsStateError);

      // …but the salvage export still hands the surviving bytes back
      // verbatim (torn tail included).
      expect(await store.rawDataBytes(id), hasLength(2 * codec.frameBytes + 6));
    });

    test(
      'a frame-aligned zero-filled tail reads as data, not damage',
      () async {
        // The accepted crash shape: an append can leave complete, frame-aligned
        // zero bytes at the tail, and detecting them is impossible without
        // fabricating (all-zero channels are plausible real readings) — so the
        // loader must return them as ordinary frames.
        const id = '2026-08-28T14-30-12-zero';
        await seedSession(
          id,
          frames: const [
            [5, 5, 5, 5],
            [6, 6, 6, 6],
          ],
        );
        final handle = await File(
          '${tmp.path}/sessions/$id/data.raw',
        ).open(mode: FileMode.append);
        await handle.writeFrom(Uint8List(codec.frameBytes));
        await handle.close();

        final loaded = await store.loadSession(id);
        expect(loaded.sampleCount, 3);
        expect(loaded.channels[0], [5, 6, 0]);
        expect(loaded.gaps.contains(2), isFalse);
      },
    );

    test('a malformed directory name is a damaged entry', () async {
      const codec = SessionChunkCodec(kAdcChannelCount);
      final sink = await backend.createSession(
        'junk',
        encodeSessionMeta(testMeta()),
        codec.pack(2, (s, ch) => 1),
      );
      await sink.close();

      final damaged = (await catalog()).damaged;
      expect(damaged, hasLength(1));
      expect(damaged.single.id, 'junk');
      expect(damaged.single.reason, contains('malformed'));
    });

    test('loadSession throws on an impossible frame shape', () async {
      const codec = SessionChunkCodec(kAdcChannelCount);
      final data = codec.pack(2, (s, ch) => 1);
      codec.fillGapSentinels(data, [(0, 1)]); // gap at frame 0
      final sink = await backend.createSession(
        '2026-08-28T14-30-12-bad0',
        encodeSessionMeta(testMeta()),
        data,
      );
      await sink.close();
      await backend.touchFinal('2026-08-28T14-30-12-bad0');

      await expectLater(
        store.loadSession('2026-08-28T14-30-12-bad0'),
        throwsStateError,
      );
    });

    test(
      'edits overlay the summary; a torn trailing edit costs only itself',
      () async {
        await seedSession('2026-08-28T14-30-12-edit');
        final files = backend;

        // Rename: one whole-snapshot edit line.
        await store.editSession(
          '2026-08-28T14-30-12-edit',
          (current) => SessionEdit(
            name: 'renamed',
            notes: current.notes,
            visibleChannels: current.visibleChannels,
          ),
        );
        expect(
          (await catalog()).session('2026-08-28T14-30-12-edit')!.name,
          'renamed',
        );

        // Simulate a crash mid-edit: garbage behind the last complete line.
        await files.appendJournal(
          '2026-08-28T14-30-12-edit',
          Uint8List.fromList('{"name":"torn'.codeUnits),
        );
        expect(
          (await catalog()).session('2026-08-28T14-30-12-edit')!.name,
          'renamed',
        );

        // The next edit truncates the torn tail first (notes path), and the
        // earlier edit survives.
        await store.editSession(
          '2026-08-28T14-30-12-edit',
          (current) => SessionEdit(
            name: current.name,
            notes: 'after tear',
            visibleChannels: current.visibleChannels,
          ),
        );
        final summary = (await catalog()).session('2026-08-28T14-30-12-edit')!;
        expect(summary.name, 'renamed');
        expect(summary.notes, 'after tear');

        final journal = parseSessionJournal(
          (await files.readJournal('2026-08-28T14-30-12-edit'))!,
        );
        expect(
          journal.completeBytes,
          (await files.readJournal('2026-08-28T14-30-12-edit'))!.lengthInBytes,
        );
      },
    );

    test('usedBytes seeds from the scan; delete removes the session', () async {
      expect(await store.usedBytes(), 0);
      await seedSession('2026-08-28T14-30-12-del0');
      // The store never saw this write (seeded straight onto the backend),
      // so only a publish — the ledger's re-seed — learns about it.
      await store.refreshCatalog();
      final used = await store.usedBytes();
      expect(used, greaterThan(2 * kAdcChannelCount * 4));

      await store.deleteSession('2026-08-28T14-30-12-del0');
      expect(readyCatalog().sessions, isEmpty);
      expect(await store.usedBytes(), 0);
    });

    test('usedBytes folds in a recording without any re-scan', () async {
      await store.ensureCatalogLoaded();
      final metaBytes = encodeSessionMeta(testMeta());
      final firstData = codec.pack(1, (s, ch) => 7);
      final appended = codec.pack(3, (s, ch) => 9);

      final before = await store.usedBytes();
      final sink = await store.createDataSink(
        meta: testMeta(),
        firstData: firstData,
      );
      await sink.append(appended);
      await sink.close();

      expect(
        await store.usedBytes(),
        before + metaBytes.length + firstData.length + appended.length,
      );
    });

    test('usedBytes tracks journal growth through edits', () async {
      const id = '2026-08-28T14-30-12-grow';
      await seedSession(id);
      await store.refreshCatalog();
      final before = await store.usedBytes();
      final oldJournalBytes = (await backend.readJournal(id))!.length;

      await store.editSession(
        id,
        (current) => SessionEdit(
          name: 'a considerably longer name than the default',
          notes: current.notes,
          visibleChannels: current.visibleChannels,
        ),
      );

      final newJournalBytes = (await backend.readJournal(id))!.length;
      expect(newJournalBytes, greaterThan(oldJournalBytes));
      expect(
        await store.usedBytes(),
        before + newJournalBytes - oldJournalBytes,
      );
    });

    test('delete destroys only the layout\'s named files', () async {
      // A crash-at-create dir (no final marker) deletes fine: absent named
      // files are skipped deliberately.
      const partial = '2026-08-28T14-30-12-part';
      final sink = await backend.createSession(
        partial,
        encodeSessionMeta(testMeta()),
        Uint8List(0),
      );
      await sink.close();
      await store.deleteSession(partial);
      expect(Directory('${tmp.path}/sessions/$partial').existsSync(), isFalse);

      // An entry the store never wrote is never destroyed: the delete
      // refuses loudly BEFORE touching anything, so the failed operation
      // leaves the session intact, not half-destroyed.
      const id = '2026-08-28T14-30-12-keep';
      await seedSession(id);
      final intruder = File('${tmp.path}/sessions/$id/not-ours.txt')
        ..writeAsStringSync('user content');
      await expectLater(
        store.deleteSession(id),
        throwsA(isA<FileSystemException>()),
      );
      expect(intruder.existsSync(), isTrue);
      expect(File('${tmp.path}/sessions/$id/meta').existsSync(), isTrue);
      expect(File('${tmp.path}/sessions/$id/data.raw').existsSync(), isTrue);
      expect((await catalog()).session(id), isNotNull);

      // With the intruder gone, the same delete succeeds.
      intruder.deleteSync();
      await store.deleteSession(id);
      expect(Directory('${tmp.path}/sessions/$id').existsSync(), isFalse);
    });

    test('raw exports refuse what is not there', () async {
      const codec = SessionChunkCodec(kAdcChannelCount);
      final sink = await backend.createSession(
        '2026-08-28T14-30-12-raw0',
        encodeSessionMeta(testMeta()),
        Uint8List(0),
      );
      await sink.close();
      await expectLater(
        store.rawDataBytes('2026-08-28T14-30-12-raw0'),
        throwsStateError,
      );
      expect(codec.framesOf(Uint8List(0)), 0);
    });
  });
}

/// Sink-seam double: collects appends, acks with the true cumulative length.
class _CollectSink implements SessionDataSink {
  _CollectSink(this.id);

  @override
  final String id;

  final appends = <Uint8List>[];
  int _length = 0;

  @override
  Future<int> append(Uint8List bytes) async {
    appends.add(bytes);
    _length += bytes.lengthInBytes;
    return _length;
  }

  @override
  Future<void> close() async {}
}

/// Wraps a real sink, letting the test substitute the append ack or the
/// close.
class _WrapSink implements SessionDataSink {
  _WrapSink(this.inner, {required this.onAppend, this.onClose});

  final SessionDataSink inner;
  final Future<int> Function(Uint8List bytes) onAppend;
  final Future<void> Function()? onClose;

  @override
  String get id => inner.id;

  @override
  Future<int> append(Uint8List bytes) => onAppend(bytes);

  @override
  Future<void> close() => onClose != null ? onClose!() : inner.close();
}

class _FaultBackend implements SessionFilesBackend {
  _FaultBackend(this.inner);

  final SessionFilesBackend inner;
  bool failListings = false;

  /// One-shot faults: each throws on exactly that many subsequent calls,
  /// then behaves (the transient-failure seam for the retry tests).
  int failNextListings = 0;
  int failNextJournalReads = 0;

  /// Emulates the native backend's torn-create window (dir + journal
  /// landed, the first data append throws) for the publish-on-tear test.
  bool failCreateAfterJournal = false;

  /// The completion-marker write fails (quota, a vanished worker): the
  /// finalize-time interrupted-verdict test.
  bool failTouchFinal = false;

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) {
    if (failCreateAfterJournal) {
      final dir = Directory('${(inner as IoSessionFilesBackend).root}/$id')
        ..createSync(recursive: true);
      File('${dir.path}/$sessionJournalFile').writeAsBytesSync(metaBytes);
      throw StateError('first append failed');
    }
    return inner.createSession(id, metaBytes, firstData);
  }

  @override
  Future<List<String>> listDirIds() {
    if (failListings || failNextListings > 0) {
      if (failNextListings > 0) failNextListings--;
      throw StateError('listing failed');
    }
    return inner.listDirIds();
  }

  @override
  Future<Uint8List?> readJournal(String id) {
    if (failNextJournalReads > 0) {
      failNextJournalReads--;
      throw StateError('journal read failed');
    }
    return inner.readJournal(id);
  }

  @override
  Future<Uint8List?> readData(String id) => inner.readData(id);

  @override
  Future<int> dataByteLength(String id) => inner.dataByteLength(id);

  @override
  Future<bool> isFinalized(String id) => inner.isFinalized(id);

  @override
  Future<void> touchFinal(String id) {
    if (failTouchFinal) throw StateError('marker write failed');
    return inner.touchFinal(id);
  }

  @override
  Future<void> truncateJournal(String id, int bytes) =>
      inner.truncateJournal(id, bytes);

  @override
  Future<void> appendJournal(String id, Uint8List bytes) =>
      inner.appendJournal(id, bytes);

  @override
  Future<void> delete(String id) => inner.delete(id);
}
