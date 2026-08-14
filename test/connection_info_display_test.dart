import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/connection_info_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCard(
    WidgetTester tester, {
    int? mtu,
    int? minPacketBytes,
    int? maxPacketBytes,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionInfoCard(
            mtu: mtu,
            minPacketBytes: minPacketBytes,
            maxPacketBytes: maxPacketBytes,
          ),
        ),
      ),
    );
  }

  testWidgets('omits ATT MTU when null; dashes unread packet sizes', (
    tester,
  ) async {
    await pumpCard(tester);
    expect(find.text('ATT MTU'), findsNothing);
    expect(find.text('Min packet size'), findsOneWidget);
    expect(find.text('Max packet size'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('shows ATT MTU and packet extremes when present', (tester) async {
    await pumpCard(tester, mtu: 247, minPacketBytes: 182, maxPacketBytes: 242);
    expect(find.text('ATT MTU'), findsOneWidget);
    expect(find.text('247'), findsOneWidget);
    expect(find.text('182 B'), findsOneWidget);
    expect(find.text('242 B'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });
}
