import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/calibration.dart';

/// Tests for the load cell bank and per-channel assignment persistence in
/// [AppSettings] (SharedPreferences backed by the in-memory mock).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> settledSettings() async {
    final settings = AppSettings();
    // Let the constructor's async prefs load resolve (a few microtask turns).
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return settings;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('load cell bank', () {
    test('defaults: empty bank, all channels unassigned', () async {
      final s = await settledSettings();
      expect(s.loadCellBank, isEmpty);
      expect(s.channelLoadCellIds, everyElement(isNull));
      expect(s.loadCellForChannel(0), isNull);
    });

    test('save adds a profile and persists across instances', () async {
      final s = await settledSettings();
      await s.saveLoadCell(
        LoadCellProfile(
          id: 'a',
          name: 'Ref',
          capacityKg: 100,
          sensitivityMvV: 2.0123,
        ),
      );
      expect(s.loadCellBank, hasLength(1));

      final s2 = await settledSettings();
      expect(s2.loadCellBank, hasLength(1));
      expect(s2.loadCellBank.single.name, 'Ref');
      expect(s2.loadCellBank.single.sensitivityMvV, closeTo(2.0123, 1e-12));
    });

    test('save replaces by id (edits propagate)', () async {
      final s = await settledSettings();
      await s.saveLoadCell(
        LoadCellProfile(id: 'a', capacityKg: 100, sensitivityMvV: 2),
      );
      await s.saveLoadCell(
        LoadCellProfile(
          id: 'a',
          name: 'Edited',
          capacityKg: 200,
          sensitivityMvV: 2,
        ),
      );
      expect(s.loadCellBank, hasLength(1));
      expect(s.loadCellBank.single.capacityKg, 200);
    });

    test(
      'assignment resolves and persists; delete falls back to unassigned',
      () async {
        final s = await settledSettings();
        await s.saveLoadCell(
          LoadCellProfile(id: 'a', capacityKg: 100, sensitivityMvV: 2),
        );
        await s.assignLoadCell(1, 'a');
        expect(s.loadCellForChannel(1)?.id, 'a');
        expect(s.channelsUsing('a'), [2]);

        final s2 = await settledSettings();
        expect(s2.loadCellForChannel(1)?.id, 'a');

        await s2.deleteLoadCell('a');
        expect(s2.loadCellBank, isEmpty);
        expect(s2.loadCellForChannel(1), isNull);

        final s3 = await settledSettings();
        expect(s3.loadCellForChannel(1), isNull);
      },
    );

    test(
      'generic find-or-create dedupes; named or corrected cells are not reused',
      () async {
        final s = await settledSettings();
        final first = await s.findOrCreateGenericCell(
          capacityKg: 200,
          sensitivityMvV: 2,
        );
        final again = await s.findOrCreateGenericCell(
          capacityKg: 200,
          sensitivityMvV: 2,
        );
        expect(again.id, first.id);
        expect(s.loadCellBank, hasLength(1));

        // A named profile with the same values is NOT a generic.
        await s.saveLoadCell(
          LoadCellProfile(
            id: 'named',
            name: 'Mine',
            capacityKg: 200,
            sensitivityMvV: 2,
          ),
        );
        final third = await s.findOrCreateGenericCell(
          capacityKg: 200,
          sensitivityMvV: 2,
        );
        expect(third.id, first.id);
        expect(s.loadCellBank, hasLength(2));

        // A span-corrected profile is not reused as a generic either.
        await s.saveLoadCell(
          LoadCellProfile(
            id: 'corr',
            capacityKg: 200,
            sensitivityMvV: 2,
            span: 1.01,
          ),
        );
        final fourth = await s.findOrCreateGenericCell(
          capacityKg: 200,
          sensitivityMvV: 2,
        );
        expect(fourth.id, first.id);
        expect(s.loadCellBank, hasLength(3));
      },
    );

    test(
      'a corrupt bank document degrades to empty without throwing',
      () async {
        SharedPreferences.setMockInitialValues({
          'load_cell_bank': 'not json',
          'channel_load_cells': '[1,2]',
        });
        final s = await settledSettings();
        expect(s.loadCellBank, isEmpty);
        expect(s.channelLoadCellIds, everyElement(isNull));
      },
    );
  });
}
