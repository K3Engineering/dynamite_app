import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/storage_capacity.dart';
import 'package:dynamite_app/widgets/storage_capacity_strip.dart';

/// Tests for the storage strip widgets' presentation: the native
/// [StorageCapacityStrip]'s usage/runway line and the web
/// [StorageEvictionWarning] line.
void main() {
  const gb = 1024 * 1024 * 1024;

  testWidgets('capacity strip shows usage, free space and runway', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StorageCapacityStrip(
            capacity: StorageCapacity(
              usedBytes: 2 * gb,
              availableBytes: 38 * gb,
            ),
          ),
        ),
      ),
    );

    // 38 GB x 0.9 / 16 kB/s ≈ 26.5 days of runway, floored.
    expect(
      find.text('2.0 GB used · 38 GB free · ≈ 26 d of recording left'),
      findsOneWidget,
    );
  });

  testWidgets('eviction warning line', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StorageEvictionWarning())),
    );

    expect(
      find.text(
        'The browser may delete stored sessions when the device runs low on '
        'storage. Export important sessions to CSV to keep them safe. Install the native '
        'app for permanent storage.',
      ),
      findsOneWidget,
    );
  });
}
