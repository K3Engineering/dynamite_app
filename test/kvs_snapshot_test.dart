import 'package:flutter_test/flutter_test.dart';

import 'helpers/flash_docs.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';

void main() {
  test('KvsSnapshot sorts keys in each folder', () {
    final snapshot = KvsSnapshot(
      factory: const {'z': 'factory', 'a': '1'},
      user: const {'z': 'user', 'lc0.cap': '200'},
    );

    expect(snapshot.factory.keys, ['a', 'z']);
    expect(snapshot.user.keys, ['lc0.cap', 'z']);
  });

  test('withUserSlots replaces schema slots and preserves unknown keys', () {
    final snapshot = KvsSnapshot(
      factory: const {'adc_fsr': '1.2'},
      user: const {'lc0.cap': '200', 'lc0.sens': '2', 'lc3.tare': '123'},
    );

    final saved = snapshot.withUserSlots({'lc1.cap': '100', 'lc1.sens': '2'});
    expect(saved.user, {'lc1.cap': '100', 'lc1.sens': '2', 'lc3.tare': '123'});
    expect(saved.factory, {'adc_fsr': '1.2'});
  });

  test('JSON round-trips the folder-separated raw values', () {
    final snapshot = KvsSnapshot(
      factory: const {'b': '2', 'a': '1'},
      user: const {'lc0.cap': '200'},
    );
    final back = KvsSnapshot.fromJson(snapshot.toJson());

    expect(back.factory, snapshot.factory);
    expect(back.user, snapshot.user);
    expect(
      () => KvsSnapshot.fromJson(const {
        'factory': {'a': 1},
        'user': <String, String>{},
      }),
      throwsFormatException,
    );
  });

  test('fromFlashDoc routes exact slot keys to User', () {
    final snapshot = kvsFromDoc(
      'charging=enabled\nlc0.cap=200\nlc0.sens=2\nlc.future=keep',
    );

    expect(snapshot.factory, {'charging': 'enabled', 'lc.future': 'keep'});
    expect(snapshot.user, {'lc0.cap': '200', 'lc0.sens': '2'});
  });

  test('invalid Factory data becomes an invalid board, slots still parse', () {
    final flash = DeviceFlash.fromKvs(
      kvsFromDoc(
        'adc_fsr=1.2\nexc=soon\nafe_gain=101\nlc0.cap=200\nlc0.sens=2',
      ),
      pgaGains: const [1, 1, 1, 1],
    );

    expect(flash.board, isA<InvalidBoardCalibration>());
    expect(
      (flash.board as InvalidBoardCalibration).detail,
      contains('bad exc'),
    );
    expect(flash.slots.slots[0]?.cell.capacityKg, 200);
  });
}
