import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/screens/another_tab_screen.dart';

void main() {
  testWidgets('waiting overlay shows the other-tab message and no actions', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AnotherTabScreen()));

    expect(find.text('Dynamite is open in another tab'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    // No buttons: the only way forward is closing the primary tab.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ButtonStyleButton ||
            w is IconButton ||
            w is FloatingActionButton,
      ),
      findsNothing,
    );
  });
}
