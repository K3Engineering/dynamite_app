import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/models/display_unit.dart';

/// Tests for [AppSettings] persistence (SharedPreferences backed by the
/// in-memory mock). The constructor loads synchronously from the injected
/// prefs instance, so no settle is needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> newSettings() async =>
      AppSettings(prefs: await SharedPreferences.getInstance());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults: mV/V unit, all channels active', () async {
    final s = await newSettings();
    expect(s.displayUnit, DisplayUnit.mVv);
    expect(s.activeChannels, everyElement(isTrue));
  });

  test('display unit persists across instances', () async {
    final s = await newSettings();
    await s.setDisplayUnit(DisplayUnit.kgf);

    final s2 = await newSettings();
    expect(s2.displayUnit, DisplayUnit.kgf);
  });
}
