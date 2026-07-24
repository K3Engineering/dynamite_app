import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/live_tab.dart';

/// Layout contract for the Live tab's action row: the custom-built tare
/// split button must render at the same height as the adjacent FilledButton
/// (REC). M3 buttons use a 40dp minimum height run through the theme's
/// visual density — VisualDensity.compact (desktop platforms, which also
/// covers desktop-web browsers) subtracts 8dp — so a hardcoded height on
/// the custom button drifts out of sync with the real button on desktop.
///
/// ActionButtons is pumped directly (no BLE harness): the pill heights are
/// a pure function of the theme's platform/density.
void main() {
  Widget harness(TargetPlatform platform) => MaterialApp(
    theme: ThemeData(platform: platform),
    home: Scaffold(
      body: Center(
        child: ActionButtons(
          isRecording: false,
          onToggleRecord: () {},
          onTare: () {},
          onTareChannel: (_) {},
          channelLabels: const ['Ch 1', 'Ch 2'],
        ),
      ),
    ),
  );

  /// The visible pill of the REC button (FilledButton's inner Material;
  /// the button widget itself is taller — padded to a 48dp tap target).
  Size recPillSize(WidgetTester tester) => tester.getSize(
    find.descendant(of: find.byType(FilledButton), matching: find.byType(Material)),
  );

  /// The tare split button's own Material — the nearest Material ancestor
  /// of its 'TARE' label.
  Size tarePillSize(WidgetTester tester) => tester.getSize(
    find
        .ancestor(of: find.text('TARE'), matching: find.byType(Material))
        .first,
  );

  testWidgets('tare and REC pills match at desktop density', (tester) async {
    await tester.pumpWidget(harness(TargetPlatform.windows));

    expect(tarePillSize(tester).height, recPillSize(tester).height);
    // Compact density: 40 - 8 = 32 for both.
    expect(recPillSize(tester).height, 32.0);
  });

  testWidgets('tare and REC pills match at mobile density', (tester) async {
    await tester.pumpWidget(harness(TargetPlatform.android));

    expect(tarePillSize(tester).height, recPillSize(tester).height);
    // Standard density: the unadjusted 40dp minimum for both.
    expect(recPillSize(tester).height, 40.0);
  });
}
