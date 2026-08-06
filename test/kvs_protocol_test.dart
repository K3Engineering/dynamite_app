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
      expect(encodeKvsDelete(kvsFolderFactory, 'ch0.raw'), 'DELFch0.raw');
      expect(encodeKvsIndex(kvsFolderFactory, 0), 'IDXF0');
      // IDX numbers are hex text (firmware parses base 16).
      expect(encodeKvsIndex(kvsFolderFactory, 26), 'IDXF1a');
    });

    test('rejects keys/values beyond the firmware limits', () {
      expect(() => encodeKvsGet(kvsFolderFactory, ''), throwsArgumentError);
      expect(
        () => encodeKvsGet(kvsFolderFactory, 'k' * (kvsMaxKeyLength + 1)),
        throwsArgumentError,
      );
      expect(
        () => encodeKvsSet(kvsFolderFactory, 'a=b', 'v'),
        throwsArgumentError,
      );
      expect(() => encodeKvsSet(kvsFolderFactory, 'k', ''), throwsArgumentError);
      expect(
        () => encodeKvsSet(kvsFolderFactory, 'k', 'v' * (kvsMaxValueLength + 1)),
        throwsArgumentError,
      );
      // The limits themselves are accepted.
      expect(
        encodeKvsSet(
          kvsFolderFactory,
          'k' * kvsMaxKeyLength,
          'v' * kvsMaxValueLength,
        ),
        isNotEmpty,
      );
    });
  });

  group('response parsing', () {
    test('a successful GET carries the value as payload', () {
      final r = parseKvsResponse('GETFch0.raw', frame('1GETFch0.raw=1,2,3'));
      expect(r.ok, isTrue);
      expect(r.payload, '1,2,3');
    });

    test('a successful SET carries an empty payload', () {
      final r = parseKvsResponse('SETFk=v', frame('1SETFk=v='));
      expect(r.ok, isTrue);
      expect(r.payload, isEmpty);
    });

    test('a failed command is status 0 with no payload', () {
      final r = parseKvsResponse('GETFmissing', frame('0GETFmissing'));
      expect(r.ok, isFalse);
      expect(r.payload, isEmpty);
    });

    test('payloads may contain = (values, IDX entries)', () {
      final r = parseKvsResponse('IDXF0', frame('1IDXF0=ch0.raw=21'));
      expect(r.ok, isTrue);
      expect(r.payload, 'ch0.raw=21');
    });

    test('an echo mismatch is a protocol error', () {
      expect(
        () => parseKvsResponse('GETFaaa', frame('1GETFbbb=x')),
        throwsFormatException,
      );
    });

    test('malformed frames are protocol errors', () {
      expect(
        () => parseKvsResponse('GETFa', Uint8List(0)),
        throwsFormatException,
      );
      // Success status without the '=' separator.
      expect(
        () => parseKvsResponse('GETFa', frame('1GETFa')),
        throwsFormatException,
      );
      // A status byte that is neither '0' nor '1'.
      expect(
        () => parseKvsResponse('GETFa', frame('2GETFa=x')),
        throwsFormatException,
      );
      // Echo truncated relative to the request.
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
