import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/status_colors.dart';

/// The Live tab's action row: two mode controls (record, monitor pause) and
/// the momentary TARE group. Pause and recording are mutually exclusive —
/// either would silently drop data the other promised to keep — and a
/// session freezes its tares at record start, so TARE is disabled in every
/// state that freezes or discards samples.
void main() {
  Finder byIcon(IconData icon) => find.ancestor(
    of: find.byIcon(icon),
    matching: find.bySubtype<IconButton>(),
  );

  Finder tareButton() => find.ancestor(
    of: find.text('TARE'),
    matching: find.bySubtype<OutlinedButton>(),
  );

  Future<void> pumpButtons(
    WidgetTester tester, {
    bool isRecording = false,
    bool isPaused = false,
    DateTime? sessionStartTime,
    VoidCallback? onToggleRecord,
    VoidCallback? onTogglePause,
    VoidCallback? onTare,
  }) {
    return tester.pumpWidget(
      ChangeNotifierProvider<DataHub>.value(
        value: DataHub(),
        child: MaterialApp(
          theme: ThemeData(extensions: const [StatusColors.light]),
          home: Scaffold(
            body: ActionButtons(
              isRecording: isRecording,
              isPaused: isPaused,
              sessionStartTime: sessionStartTime,
              onToggleRecord: onToggleRecord ?? () {},
              onTogglePause: onTogglePause ?? () {},
              onTare: onTare ?? () {},
              onTareSettings: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('TARE is disabled while recording', (tester) async {
    var tared = false;
    await pumpButtons(tester, isRecording: true, onTare: () => tared = true);

    expect(tester.widget<OutlinedButton>(tareButton()).onPressed, isNull);

    await tester.tap(tareButton());
    expect(tared, isFalse);
  });

  testWidgets('TARE is disabled while monitoring is paused', (tester) async {
    var tared = false;
    await pumpButtons(tester, isPaused: true, onTare: () => tared = true);

    expect(tester.widget<OutlinedButton>(tareButton()).onPressed, isNull);

    await tester.tap(tareButton());
    expect(tared, isFalse);
  });

  testWidgets('TARE is enabled while recording-free and unpaused', (
    tester,
  ) async {
    var tared = false;
    await pumpButtons(tester, onTare: () => tared = true);

    await tester.tap(tareButton());
    expect(tared, isTrue);
  });

  testWidgets('the record control is disabled while monitoring is paused', (
    tester,
  ) async {
    var toggled = false;
    await pumpButtons(
      tester,
      isPaused: true,
      onToggleRecord: () => toggled = true,
    );

    expect(
      tester.widget<IconButton>(byIcon(Icons.fiber_manual_record)).onPressed,
      isNull,
    );

    await tester.tap(byIcon(Icons.fiber_manual_record));
    expect(toggled, isFalse);
  });

  testWidgets('the pause control is disabled while recording', (tester) async {
    var toggled = false;
    await pumpButtons(
      tester,
      isRecording: true,
      onTogglePause: () => toggled = true,
    );

    expect(tester.widget<IconButton>(byIcon(Icons.pause)).onPressed, isNull);

    await tester.tap(byIcon(Icons.pause));
    expect(toggled, isFalse);
  });

  testWidgets('both mode toggles fire when free of the other mode', (
    tester,
  ) async {
    var recorded = false;
    var paused = false;
    await pumpButtons(
      tester,
      onToggleRecord: () => recorded = true,
      onTogglePause: () => paused = true,
    );

    await tester.tap(byIcon(Icons.fiber_manual_record));
    await tester.tap(byIcon(Icons.pause));
    expect(recorded, isTrue);
    expect(paused, isTrue);
  });

  testWidgets('mode captions: Record/Recording for the record control, '
      'Monitoring/Paused for the pause control', (tester) async {
    await pumpButtons(tester);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Monitoring'), findsOneWidget);

    await pumpButtons(tester, isRecording: true);
    expect(find.text('Recording'), findsOneWidget);

    await pumpButtons(tester, isPaused: true);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('a recording with a start time captions an elapsed clock', (
    tester,
  ) async {
    await pumpButtons(
      tester,
      isRecording: true,
      sessionStartTime: DateTime.now(),
    );
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('Recording'), findsNothing);
  });
}
