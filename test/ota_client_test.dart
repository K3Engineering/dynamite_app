import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/ota_client.dart';
import 'package:dynamite_app/services/ota_protocol.dart';

/// A write log entry: which endpoint, the bytes, and whether the write
/// requested no ATT response.
typedef Write = ({String endpoint, Uint8List bytes, bool withoutResponse});

/// Tests for [OtaClient] against a recorded-closure transport (the client
/// is transport-injected, so no BLE stack is involved), driven
/// deterministically with [fakeAsync].
void main() {
  const chunkSize = 100;
  const ackTimeout = Duration(seconds: 5);

  (OtaClient, List<Write>) wire() {
    final writes = <Write>[];
    final client = OtaClient(
      chunkSize: chunkSize,
      ackTimeout: ackTimeout,
      writeControl: (bytes, {withoutResponse = false}) async {
        writes.add((
          endpoint: 'control',
          bytes: Uint8List.fromList(bytes),
          withoutResponse: withoutResponse,
        ));
      },
      writeData: (bytes) async {
        writes.add((
          endpoint: 'data',
          bytes: Uint8List.fromList(bytes),
          withoutResponse: false,
        ));
      },
    );
    return (client, writes);
  }

  void reply(OtaClient client, int opcode) =>
      client.handleNotification(Uint8List.fromList([opcode]));

  /// Capture a future's outcome into [errors] (its value is dropped).
  void track(Future<Object?> f, List<Object> errors) {
    unawaited(f.then((_) {}, onError: (Object e) => errors.add(e)));
  }

  /// Push [client] through the happy-path handshake: request-ack, done-ack.
  /// Flushes microtasks around each step so awaited writes land.
  void completeHandshake(FakeAsync async, OtaClient client) {
    async.flushMicrotasks();
    reply(client, otaRequestAck);
    // One flush drains the whole chunk loop (every write future completes
    // immediately), landing the DONE write in the log.
    async.flushMicrotasks();
    reply(client, otaDoneAck);
    async.flushMicrotasks();
  }

  test('happy path: handshake order, chunked data, DONE without response', () {
    fakeAsync((async) {
      final (client, writes) = wire();
      final errors = <Object>[];
      final image = Uint8List.fromList(List.generate(250, (i) => i & 0xFF));
      final progress = <int>[];
      track(client.flash(image: image, onProgress: progress.add), errors);
      completeHandshake(async, client);

      expect(errors, isEmpty);
      expect(writes.map((w) => w.endpoint).toList(), [
        'control', // REQUEST with the declared size
        'data', 'data', 'data',
        'control', // DONE
      ]);
      expect(writes[0].bytes, encodeOtaRequest(image.length));
      expect(writes[0].withoutResponse, isFalse);
      // 250 bytes at 100-byte chunks: 100 + 100 + 50.
      expect(writes.sublist(1, 4).map((w) => w.bytes.length), [100, 100, 50]);
      expect(writes[1].bytes, image.sublist(0, 100));
      expect(writes[3].bytes, image.sublist(200));
      expect(writes[4].bytes.single, otaDoneOpcode);
      expect(writes[4].withoutResponse, isTrue);
      // Every chunk write was with-response (flow control); none of the
      // data writes set the flag.
      expect(
        writes.where((w) => w.endpoint == 'data'),
        everyElement(
          isA<Write>().having((w) => w.withoutResponse, 'w/o', false),
        ),
      );
      expect(progress, [100, 200, 250]);
    });
  });

  test('a reply sent inside the write (before it resolves) is not dropped', () {
    fakeAsync((async) {
      // The device notifies inside its write handler, so each reply can
      // reach the host ahead of the write's completion — the live wait must
      // already be armed when the bytes go out.
      late OtaClient client;
      client = OtaClient(
        chunkSize: chunkSize,
        ackTimeout: ackTimeout,
        writeControl: (bytes, {withoutResponse = false}) {
          final reply = bytes.first == otaRequestOpcode
              ? otaRequestAck
              : otaDoneAck;
          client.handleNotification(Uint8List.fromList([reply]));
          return Future<void>.value();
        },
        writeData: (_) => Future<void>.value(),
      );
      final errors = <Object>[];
      var settled = false;
      track(
        client.flash(image: Uint8List(250)).whenComplete(() => settled = true),
        errors,
      );
      async.flushMicrotasks();

      expect(settled, isTrue);
      expect(errors, isEmpty);
    });
  });

  test('REQUEST NAK aborts before any data is written', () {
    fakeAsync((async) {
      final (client, writes) = wire();
      final errors = <Object>[];
      track(client.flash(image: Uint8List(10)), errors);
      async.flushMicrotasks();
      reply(client, otaRequestNak);
      async.flushMicrotasks();

      expect(errors, hasLength(1));
      expect(errors.single, isA<OtaFlashException>());
      expect(writes.where((w) => w.endpoint == 'data'), isEmpty);
    });
  });

  test('DONE NAK reports the integrity rejection', () {
    fakeAsync((async) {
      final (client, _) = wire();
      final errors = <Object>[];
      track(client.flash(image: Uint8List(10)), errors);
      async.flushMicrotasks();
      reply(client, otaRequestAck);
      async.flushMicrotasks();
      reply(client, otaDoneNak);
      async.flushMicrotasks();

      expect(errors, hasLength(1));
      expect(errors.single, isA<OtaFlashException>());
      expect(errors.single.toString(), contains('integrity'));
    });
  });

  test('a reply that never arrives fails the flash after the timeout', () {
    fakeAsync((async) {
      final (client, _) = wire();
      final errors = <Object>[];
      track(client.flash(image: Uint8List(10)), errors);
      async.flushMicrotasks();
      // REQUEST is now outstanding and nothing answers.
      async.elapse(ackTimeout);

      expect(errors, hasLength(1));
      expect(errors.single, isA<OtaFlashException>());
      expect(errors.single.toString(), contains('Timed out'));
    });
  });

  test('abort fails the live wait', () {
    fakeAsync((async) {
      final (client, _) = wire();
      final errors = <Object>[];
      track(client.flash(image: Uint8List(10)), errors);
      async.flushMicrotasks();
      client.abort();
      async.flushMicrotasks();

      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });
  });
}
