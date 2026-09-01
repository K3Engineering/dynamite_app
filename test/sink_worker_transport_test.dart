import 'dart:async';
import 'dart:typed_data';

import 'package:dynamite_app/services/sink_worker_transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted worker double: records posts, captures the transport's
/// listeners, and lets each test drive acks/errors/terminations by hand.
class _FakeHandle implements SinkWorkerHandle {
  @override
  late void Function(SinkWorkerAck ack) onMessage;

  @override
  late void Function() onError;

  final List<SinkWorkerRequest> posts = [];
  int terminates = 0;

  /// When set, [post] throws this instead of recording.
  Object? errorOnPost;

  @override
  void post(SinkWorkerRequest request) {
    final error = errorOnPost;
    if (error != null) throw error;
    posts.add(request);
  }

  @override
  void terminate() => terminates++;

  void ackOk(int seq, {Object? result, Uint8List? bytes}) =>
      onMessage(SinkWorkerAck.ok(seq, result: result, bytes: bytes));

  void ackError(int seq, String message) =>
      onMessage(SinkWorkerAck.opError(seq, message));
}

void main() {
  late _FakeHandle handle;
  late SinkWorkerTransport transport;

  setUp(() {
    handle = _FakeHandle();
    transport = SinkWorkerTransport(handle);
  });

  SinkWorkerTransport newTransport({Duration? requestTimeout}) {
    handle = _FakeHandle();
    transport = SinkWorkerTransport(handle, requestTimeout: requestTimeout);
    return transport;
  }

  test(
    'requests post with increasing seq and acks resolve their requester',
    () async {
      final first = transport.request('probe');
      await pumpEventQueue();
      expect(handle.posts.single.seq, 0);
      expect(handle.posts.single.op, 'probe');

      handle.ackOk(0, result: 42);
      final ack = await first;
      expect(ack.result, 42);
      expect(ack.error, isNull);
    },
  );

  test('scalar params and byte payloads ride the request', () async {
    final meta = Uint8List.fromList([1, 2, 3]);
    final data = Uint8List.fromList([4, 5]);
    final pending = transport.request(
      'createSession',
      id: 'some-id',
      intParam: 128,
      bytes: meta,
      bytes2: data,
    );
    await pumpEventQueue();
    expect(handle.posts.single.id, 'some-id');
    expect(handle.posts.single.intParam, 128);
    expect(handle.posts.single.bytes, meta);
    expect(handle.posts.single.bytes2, data);
    handle.ackOk(0);
    await pending;
  });

  test(
    'one request in flight: the next posts only after the first acks',
    () async {
      final first = transport.request('probe');
      var secondRan = false;
      final second = transport
          .request('dropLegacyDb')
          .then((_) => secondRan = true);
      await pumpEventQueue();
      expect(handle.posts.map((r) => r.op), ['probe']);
      expect(secondRan, isFalse);

      handle.ackOk(0);
      await first;
      await pumpEventQueue();
      expect(handle.posts.map((r) => r.op), ['probe', 'dropLegacyDb']);
      handle.ackOk(1);
      await second;
      expect(secondRan, isTrue);
    },
  );

  test(
    'an op-error ack fails its request without latching the transport',
    () async {
      final first = transport.request('delete', id: 'gone');
      await pumpEventQueue();
      handle.ackError(0, 'no sessions root');
      await expectLater(
        first,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no sessions root'),
          ),
        ),
      );

      // The chain continues: the next request posts and acks normally.
      final second = transport.request('probe');
      await pumpEventQueue();
      expect(handle.posts, hasLength(2));
      handle.ackOk(1, result: true);
      expect((await second).result, isTrue);
      expect(handle.terminates, 0);
    },
  );

  test('an ack with an unknown seq is ignored', () async {
    handle.ackOk(99, result: 1);
    final pending = transport.request('probe');
    await pumpEventQueue();
    handle.ackOk(0);
    await pending;
  });

  test(
    'request timeout latches: terminate once, pending and future fail with the same error',
    () {
      fakeAsync((async) {
        newTransport(requestTimeout: const Duration(seconds: 1));
        late Object error1;
        unawaited(
          transport
              .request('append')
              .then<void>((_) {}, onError: (Object e) => error1 = e),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(
          error1,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        );
        expect(handle.terminates, 1);

        // Future requests fail with the latched error without posting.
        late Object error2;
        unawaited(
          transport
              .request('append')
              .then<void>((_) {}, onError: (Object e) => error2 = e),
        );
        async.flushMicrotasks();
        expect(identical(error1, error2), isTrue);
        expect(handle.posts, hasLength(1));
        expect(handle.terminates, 1);
      });
    },
  );

  test('worker error event latches the transport', () async {
    final pending = transport.request('append');
    await pumpEventQueue();
    handle.onError();
    await expectLater(pending, throwsA(isA<StateError>()));
    await expectLater(transport.request('append'), throwsA(isA<StateError>()));
    expect(handle.terminates, 1);
  });

  test(
    'a throwing post fails that request only; the transport stays live',
    () async {
      handle.errorOnPost = StateError('channel dead');
      await expectLater(transport.request('probe'), throwsA(isA<StateError>()));
      handle.errorOnPost = null;

      final second = transport.request('probe');
      await pumpEventQueue();
      expect(handle.posts, hasLength(1));
      handle.ackOk(1);
      await second;
      expect(handle.terminates, 0);
    },
  );

  test(
    'terminate closes the transport: pending and future requests fail',
    () async {
      final pending = transport.request('append');
      await pumpEventQueue();
      transport.terminate();
      await expectLater(pending, throwsA(isA<StateError>()));
      await expectLater(
        transport.request('append'),
        throwsA(isA<StateError>()),
      );
      expect(handle.terminates, 1);

      // A second terminate is a no-op on the already-latched transport.
      transport.terminate();
      expect(handle.terminates, 1);
    },
  );

  test('latch fails queued-but-unposted requests too', () async {
    final first = transport.request('a');
    final second = transport.request('b');
    await pumpEventQueue();
    handle.onError();
    await expectLater(first, throwsA(isA<StateError>()));
    await expectLater(second, throwsA(isA<StateError>()));
    expect(handle.posts, hasLength(1)); // b never posted.
  });
}
