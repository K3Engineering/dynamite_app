import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/services/data_hub.dart';

/// A session freezes its tares at record start, so re-zeroing mid-recording
/// would desync the live display from the export: the TARE button is disabled
/// while [RecordingController.sessionInProgress] is true.
void main() {
  Finder tareButton() => find.ancestor(
    of: find.text('TARE'),
    matching: find.bySubtype<OutlinedButton>(),
  );

  Future<void> pumpButtons(
    WidgetTester tester, {
    required bool isRecording,
    required VoidCallback onTare,
    DateTime? sessionStartTime,
  }) {
    return tester.pumpWidget(
      ChangeNotifierProvider<DataHub>.value(
        value: DataHub(),
        child: MaterialApp(
          home: Scaffold(
            body: ActionButtons(
              isRecording: isRecording,
              sessionStartTime: sessionStartTime,
              onToggleRecord: () {},
              onTare: onTare,
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

  testWidgets('TARE is enabled when not recording', (tester) async {
    var tared = false;
    await pumpButtons(tester, isRecording: false, onTare: () => tared = true);

    await tester.tap(tareButton());
    expect(tared, isTrue);
  });

  testWidgets('the record button reads REC when idle, STOP when recording', (
    tester,
  ) async {
    await pumpButtons(tester, isRecording: false, onTare: () {});
    expect(find.text('REC'), findsOneWidget);

    await pumpButtons(tester, isRecording: true, onTare: () {});
    expect(find.text('STOP'), findsOneWidget);
  });

  testWidgets('with a start time the STOP label shows an elapsed clock', (
    tester,
  ) async {
    await pumpButtons(
      tester,
      isRecording: true,
      onTare: () {},
      sessionStartTime: DateTime.now(),
    );
    expect(find.text('STOP 00:00'), findsOneWidget);
    expect(find.text('STOP'), findsNothing);
  });
}
