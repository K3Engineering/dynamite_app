import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_flash.dart';

void main() {
  test('KvsSnapshot sorts keys in each folder', () {
    final snapshot = KvsSnapshot(
      factory: {'z': 'factory', 'a': '1'},
      user: {'z': 'user', 'lc0.cap': '200'},
    );

    expect(snapshot.factory.keys, ['a', 'z']);
    expect(snapshot.user.keys, ['lc0.cap', 'z']);
  });

  test('KvsSnapshot rejects control characters in keys and values', () {
    for (final badCodeUnit in [0x00, 0x09, 0x0A, 0x1F, 0x7F]) {
      final bad = String.fromCharCode(badCodeUnit);
      expect(
        () => KvsSnapshot(factory: {'a': '1$bad'}, user: const {}),
        throwsFormatException,
        reason: 'value 0x${badCodeUnit.toRadixString(16)}',
      );
      expect(
        () => KvsSnapshot(factory: {'a$bad': '1'}, user: const {}),
        throwsFormatException,
        reason: 'key 0x${badCodeUnit.toRadixString(16)}',
      );
    }
  });

  test('withUserSlots replaces schema slots and preserves unknown keys', () {
    final snapshot = KvsSnapshot(
      factory: {'adc_fsr': '1.2'},
      user: {'lc0.cap': '200', 'lc0.sens': '2', 'lc3.tare': '123'},
    );

    final saved = snapshot.withUserSlots({'lc1.cap': '100', 'lc1.sens': '2'});
    expect(saved.user, {'lc1.cap': '100', 'lc1.sens': '2', 'lc3.tare': '123'});
    expect(saved.factory, {'adc_fsr': '1.2'});
  });

  test('JSON round-trips the folder-separated raw values', () {
    final snapshot = KvsSnapshot(
      factory: {'b': '2', 'a': '1'},
      user: {'lc0.cap': '200'},
    );
    final back = KvsSnapshot.fromJson(snapshot.toJson());

    expect(back.factory, snapshot.factory);
    expect(back.user, snapshot.user);
    expect(
      () => KvsSnapshot.fromJson({
        'factory': {'a': 1},
        'user': const <String, String>{},
      }),
      throwsFormatException,
    );
  });

  test('fromFlashDoc routes exact slot keys to User', () {
    final snapshot = KvsSnapshot.fromFlashDoc(
      'charging=enabled\nlc0.cap=200\nlc0.sens=2\nlc.future=keep',
    );

    expect(snapshot.factory, {'charging': 'enabled', 'lc.future': 'keep'});
    expect(snapshot.user, {'lc0.cap': '200', 'lc0.sens': '2'});
  });
}
