import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/kvs_protocol.dart';

Uint8List frame(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('request encoding', () {
    test('builds the firmware command strings', () {
      expect(encodeKvsGet(kvsFolderFactory, 'ch0.raw'), 'GETFch0.raw');
      expect(encodeKvsSet(kvsFolderUser, 'lc0.cap', '200'), 'SETUlc0.cap=200');
      expect(encodeKvsDelete(kvsFolderUser, 'lc0.name'), 'DELUlc0.name');
      expect(encodeKvsIndex(kvsFolderFactory, 0), 'IDXF0');
      // IDX numbers are hex text (firmware parses base 16).
      expect(encodeKvsIndex(kvsFolderFactory, 26), 'IDXF1a');
    });

    test('SET/DEL refuse the Factory partition (read-only to the app)', () {
      // Board calibration belongs to factory tooling; the app reads it but
      // must never write it — asserted at the frame-build choke point.
      expect(
        () => encodeKvsSet(kvsFolderFactory, 'ch0.raw', '1'),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => encodeKvsDelete(kvsFolderFactory, 'ch0.raw'),
        throwsA(isA<AssertionError>()),
      );
      // Reads and the writable folders are unaffected.
      expect(encodeKvsGet(kvsFolderFactory, 'ch0.raw'), isNotEmpty);
      expect(encodeKvsSet(kvsFolderSettings, 'device_name', 'x'), isNotEmpty);
    });

    test('rejects keys/values beyond the firmware limits', () {
      expect(() => encodeKvsGet(kvsFolderFactory, ''), throwsArgumentError);
      expect(
        () => encodeKvsGet(kvsFolderFactory, 'k' * (kvsMaxKeyLength + 1)),
        throwsArgumentError,
      );
      expect(
        () => encodeKvsSet(kvsFolderUser, 'a=b', 'v'),
        throwsArgumentError,
      );
      expect(() => encodeKvsSet(kvsFolderUser, 'k', ''), throwsArgumentError);
      expect(
        () => encodeKvsSet(kvsFolderUser, 'k', 'v' * (kvsMaxValueLength + 1)),
        throwsArgumentError,
      );
      // The limits themselves are accepted.
      expect(
        encodeKvsSet(
          kvsFolderUser,
          'k' * kvsMaxKeyLength,
          'v' * kvsMaxValueLength,
        ),
        isNotEmpty,
      );
    });
  });

  group('response parsing', () {
    test('a successful GET carries the value as payload', () {
      final r = parseKvsResponse('GETFch0.raw', frame('1GETFch0.raw=1,2,3'))!;
      expect(r.ok, isTrue);
      expect(r.payload, '1,2,3');
    });

    test('a successful SET carries an empty payload', () {
      final r = parseKvsResponse('SETFk=v', frame('1SETFk=v='))!;
      expect(r.ok, isTrue);
      expect(r.payload, isEmpty);
    });

    test('a failed command is status 0 with no payload', () {
      final r = parseKvsResponse('GETFmissing', frame('0GETFmissing'))!;
      expect(r.ok, isFalse);
      expect(r.payload, isEmpty);
    });

    test('payloads may contain = (values, IDX entries)', () {
      final r = parseKvsResponse('IDXF0', frame('1IDXF0=ch0.raw=21'))!;
      expect(r.ok, isTrue);
      expect(r.payload, 'ch0.raw=21');
    });

    test('SET echoes with = inside the request still match', () {
      final r = parseKvsResponse(
        'SETUlc0.cap=200',
        frame('1SETUlc0.cap=200='),
      )!;
      expect(r.ok, isTrue);
      expect(r.payload, isEmpty);
    });

    test(
      'a well-formed frame for a different command is stale, not an error',
      () {
        expect(parseKvsResponse('GETFaaa', frame('1GETFbbb=x')), isNull);
        // Reject frames shorter or longer than the pending request aren't its
        // answer either (prefix-free matching, both directions).
        expect(parseKvsResponse('GETFaa', frame('0GETFa')), isNull);
        expect(parseKvsResponse('GETFaa', frame('0GETFaaX')), isNull);
        // The prefix trap that killed live commands before: a longer request's
        // late success frame while its strict prefix is pending.
        expect(parseKvsResponse('GETFabc', frame('1GETFabcX=9')), isNull);
      },
    );

    test('garbled frames are protocol errors', () {
      expect(
        () => parseKvsResponse('GETFa', Uint8List(0)),
        throwsFormatException,
      );
      // Success status without the '=' separator (matching echo).
      expect(
        () => parseKvsResponse('GETFa', frame('1GETFa')),
        throwsFormatException,
      );
      // A status byte that is neither '0' nor '1'.
      expect(
        () => parseKvsResponse('GETFa', frame('2GETFa=x')),
        throwsFormatException,
      );
      // Success frame with no separator anywhere.
      expect(
        () => parseKvsResponse('GETFaa', frame('1GETF')),
        throwsFormatException,
      );
    });
  });

  group('IDX payload parsing', () {
    test('splits key and hex type at the last =', () {
      final e = parseKvsIndexPayload('ch0.raw=21');
      expect(e?.$1, 'ch0.raw');
      expect(e?.$2, 0x21);
    });

    test('rejects malformed payloads', () {
      expect(parseKvsIndexPayload(''), isNull);
      expect(parseKvsIndexPayload('=21'), isNull);
      expect(parseKvsIndexPayload('key='), isNull);
      expect(parseKvsIndexPayload('key=zz'), isNull);
    });
  });
}
