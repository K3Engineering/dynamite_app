import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/app_theme.dart';
import 'package:dynamite_app/status_colors.dart';

void main() {
  test('light and dark themes keep their brightness-specific roles paired', () {
    final cases = [
      (
        theme: AppTheme.light,
        brightness: Brightness.light,
        status: StatusColors.light,
      ),
      (
        theme: AppTheme.dark,
        brightness: Brightness.dark,
        status: StatusColors.dark,
      ),
    ];

    for (final c in cases) {
      final colors = c.theme.colorScheme;
      expect(colors.brightness, c.brightness);
      expect(c.theme.extension<StatusColors>(), same(c.status));
      expect(colors.errorContainer, colors.error);
      expect(colors.onErrorContainer, colors.onError);
      expect(c.theme.navigationBarTheme.iconTheme, isNotNull);
      expect(c.theme.navigationBarTheme.labelTextStyle, isNotNull);
    }
  });

  test('selected ListTile foreground is not themed globally', () {
    expect(AppTheme.light.listTileTheme.selectedColor, isNull);
    expect(AppTheme.dark.listTileTheme.selectedColor, isNull);
  });
}
