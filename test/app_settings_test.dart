import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/force_unit.dart';

/// Tests for [AppSettings] persistence (SharedPreferences backed by the
/// in-memory mock).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> settledSettings() async {
    final settings = AppSettings();
    // Let the constructor's async prefs load resolve (a few microtask turns).
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return settings;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults: mV/V unit, all channels active', () async {
    final s = await settledSettings();
    expect(s.displayUnit, ForceUnit.mVv);
    expect(s.activeChannels, everyElement(isTrue));
  });

  test('display unit persists across instances', () async {
    final s = await settledSettings();
    await s.setDisplayUnit(ForceUnit.kgf);

    final s2 = await settledSettings();
    expect(s2.displayUnit, ForceUnit.kgf);
  });

  test('legacy pre-slot keys are erased on load', () async {
    SharedPreferences.setMockInitialValues({
      'channel_labels': ['a', 'b', 'c', 'd'],
      'load_cell_bank': '[{"id":"x"}]',
      'channel_load_cells': '["x",null,null,null]',
    });
    await settledSettings();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('channel_labels'), isNull);
    expect(prefs.getString('load_cell_bank'), isNull);
    expect(prefs.getString('channel_load_cells'), isNull);
  });
}
