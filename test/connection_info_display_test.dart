import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/info_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCard(
    WidgetTester tester, {
    int? mtu,
    int? minPacketBytes,
    int? maxPacketBytes,
    Duration? uptime,
    int? lostSamples,
    double? rateDeviationHz,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionInfoCard(
            mtu: mtu,
            minPacketBytes: minPacketBytes,
            maxPacketBytes: maxPacketBytes,
            uptime: uptime,
            lostSamples: lostSamples,
            rateDeviationHz: rateDeviationHz,
          ),
        ),
      ),
    );
  }

  testWidgets('omits ATT MTU when null; dashes everything not yet known', (
    tester,
  ) async {
    await pumpCard(tester);
    expect(find.text('ATT MTU'), findsNothing);
    for (final label in [
      'Min packet size',
      'Max packet size',
      'Uptime',
      'Samples lost',
      'Rate deviation',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('—'), findsNWidgets(5));
  });

  testWidgets('shows ATT MTU and packet extremes when present', (tester) async {
    await pumpCard(tester, mtu: 247, minPacketBytes: 182, maxPacketBytes: 242);
    expect(find.text('ATT MTU'), findsOneWidget);
    expect(find.text('247'), findsOneWidget);
    expect(find.text('182 B'), findsOneWidget);
    expect(find.text('242 B'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(3));
  });

  testWidgets('shows the stream stats when present', (tester) async {
    await pumpCard(
      tester,
      uptime: const Duration(minutes: 3, seconds: 12),
      lostSamples: 1040,
      rateDeviationHz: -0.013,
    );
    expect(find.text('3m 12s'), findsOneWidget);
    expect(find.text('1,040'), findsOneWidget);
    expect(find.text('-0.01 Hz'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
  });
}
