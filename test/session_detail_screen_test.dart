import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/session_detail_screen.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/session_queries.dart';
import 'package:dynamite_app/widgets/empty_placeholder.dart';

/// Widget test for the Session detail screen's empty state: a session with
/// no chunks (e.g. its data was deleted externally) renders the shared
/// [EmptyPlaceholder] — the single-voice empty-state treatment used by the
/// Sessions/Devices/Live tabs — not a bare text. (The failure branch maps
/// to the same widget with the error color; no clean in-harness trigger
/// exists for it — a corrupt chunk/metadata degrades silently rather than
/// throwing.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(AppDatabase.closeInstance);

  testWidgets('a session with no chunks renders the empty placeholder', (
    tester,
  ) async {
    final sessionId = await AppDatabase.instance.createSession(
      name: 'Empty session',
      sampleRate: 1000,
      channelCount: 4,
      channelLabels: '[]',
      tares: '[]',
      calibrationJson: '[]',
      visibleChannels: '[]',
      displayUnit: 'kgf',
      deviceInfoJson: '{}',
    );
    await AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: 0,
      durationMs: 0,
      peaksRaw: '[]',
    );
    final session = (await sessionSummaryById(sessionId))!;

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
        ],
        child: MaterialApp(home: SessionDetailScreen(session: session)),
      ),
    );
    // Let the load future land; the initial spinner gives way to the
    // placeholder, after which nothing schedules frames.
    await tester.pumpAndSettle();

    expect(find.byType(EmptyPlaceholder), findsOneWidget);
    expect(find.text('No recorded data for this session'), findsOneWidget);
    expect(find.byIcon(Icons.insert_chart_outlined), findsOneWidget);

    // Unmount the screen ourselves and elapse a tick, so the zero-duration
    // timer drift schedules when the row stream's StreamBuilder unsubscribes
    // (StreamQueryStore.markAsClosed) fires now — not during the binding's
    // final teardown, where it would trip the pending-timer check (and stall
    // the instance close in tearDown). A bare pump() does NOT elapse the
    // fake clock, so give it a duration.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
