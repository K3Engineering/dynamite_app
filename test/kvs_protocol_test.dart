import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/kvs_protocol.dart';

Uint8List frame(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('request encoding', () {
    test('builds the firmware command strings', () {
      expect(encodeKvsGet(kvsFolderDevice, 'ch0.raw'), 'GETDch0.raw');
      expect(encodeKvsSet(kvsFolderExtra, 'lc0.cap', '200'), 'SETElc0.cap=200');
      expect(encodeKvsDelete(kvsFolderDevice, 'ch0.raw'), 'DELDch0.raw');
      expect(encodeKvsIndex(kvsFolderDevice, 0), 'IDXD0');
      // IDX numbers are hex text (firmware parses base 16).
      expect(encodeKvsIndex(kvsFolderDevice, 26), 'IDXD1a');
    });

    test('rejects keys/values beyond the firmware limits', () {
      expect(() => encodeKvsGet(kvsFolderDevice, ''), throwsArgumentError);
      expect(
        () => encodeKvsGet(kvsFolderDevice, 'k' * (kvsMaxKeyLength + 1)),
        throwsArgumentError,
      );
      expect(
        () => encodeKvsSet(kvsFolderDevice, 'a=b', 'v'),
        throwsArgumentError,
      );
      expect(() => encodeKvsSet(kvsFolderDevice, 'k', ''), throwsArgumentError);
      expect(
        () => encodeKvsSet(kvsFolderDevice, 'k', 'v' * (kvsMaxValueLength + 1)),
        throwsArgumentError,
      );
      // The limits themselves are accepted.
      expect(
        encodeKvsSet(
          kvsFolderDevice,
          'k' * kvsMaxKeyLength,
          'v' * kvsMaxValueLength,
        ),
        isNotEmpty,
      );
    });
  });

  group('response parsing', () {
    test('a successful GET carries the value as payload', () {
      final r = parseKvsResponse('GETDch0.raw', frame('1GETDch0.raw=1,2,3'));
      expect(r.ok, isTrue);
      expect(r.payload, '1,2,3');
    });

    test('a successful SET carries an empty payload', () {
      final r = parseKvsResponse('SETDk=v', frame('1SETDk=v='));
      expect(r.ok, isTrue);
      expect(r.payload, isEmpty);
    });

    test('a failed command is status 0 with no payload', () {
      final r = parseKvsResponse('GETDmissing', frame('0GETDmissing'));
      expect(r.ok, isFalse);
      expect(r.payload, isEmpty);
    });

    test('payloads may contain = (values, IDX entries)', () {
      final r = parseKvsResponse('IDXD0', frame('1IDXD0=ch0.raw=21'));
      expect(r.ok, isTrue);
      expect(r.payload, 'ch0.raw=21');
    });

    test('an echo mismatch is a protocol error', () {
      expect(
        () => parseKvsResponse('GETDaaa', frame('1GETDbbb=x')),
        throwsFormatException,
      );
    });

    test('malformed frames are protocol errors', () {
      expect(
        () => parseKvsResponse('GETDa', Uint8List(0)),
        throwsFormatException,
      );
      // Success status without the '=' separator.
      expect(
        () => parseKvsResponse('GETDa', frame('1GETDa')),
        throwsFormatException,
      );
      // A status byte that is neither '0' nor '1'.
      expect(
        () => parseKvsResponse('GETDa', frame('2GETDa=x')),
        throwsFormatException,
      );
      // Echo truncated relative to the request.
      expect(
        () => parseKvsResponse('GETDaa', frame('1GETD')),
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
