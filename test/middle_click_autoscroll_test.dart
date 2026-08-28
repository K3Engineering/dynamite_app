import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/widgets/middle_click_autoscroll.dart';

void main() {
  testWidgets('middle-button hold scrolls proportionally; release stops it', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MiddleClickAutoscroll(
            controller: controller,
            child: ListView(
              controller: controller,
              children: [
                for (var i = 0; i < 100; i++)
                  SizedBox(height: 50, child: Text('row $i')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(controller.position.pixels, 0);

    // Middle click without leaving the dead zone: no scroll.
    final idle = await tester.startGesture(
      const Offset(400, 300),
      buttons: kMiddleMouseButton,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.position.pixels, 0);

    // Drag down and hold: scrolls down, keeps scrolling without further moves.
    await idle.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 100));
    final scrolled = controller.position.pixels;
    expect(scrolled, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.pixels, greaterThan(scrolled));

    // Release: motion stops at the current offset.
    await idle.up();
    final stopped = controller.position.pixels;
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.position.pixels, stopped);
  });
}
