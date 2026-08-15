import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/storage_capacity.dart';
import 'package:dynamite_app/widgets/storage_capacity_strip.dart';

/// Tests for [StorageCapacityStrip]'s presentation: the usage/runway line
/// (native phrasing on the test host — kIsWeb is false), and the reclaim
/// warning's visibility keyed to persistence.
void main() {
  const gb = 1024 * 1024 * 1024;

  Widget wrap(StorageCapacity capacity) => MaterialApp(
    home: Scaffold(body: StorageCapacityStrip(capacity: capacity)),
  );

  testWidgets('shows usage, free space and runway', (tester) async {
    await tester.pumpWidget(
      wrap(
        const StorageCapacity(
          usedBytes: 2 * gb,
          availableBytes: 38 * gb,
          isPersistent: true,
        ),
      ),
    );

    // 38 GB x 0.9 / 16 kB/s ≈ 26.5 days of runway, floored.
    expect(
      find.text('2.0 GB used · 38 GB free · ≈ 26 d of recording left'),
      findsOneWidget,
    );
  });

  testWidgets('reclaim warning only while storage is not persistent', (
    tester,
  ) async {
    const warning =
        'The browser may reclaim this space when storage runs low. '
        'The native iOS and Android apps have larger, permanent storage.';

    await tester.pumpWidget(
      wrap(
        const StorageCapacity(
          usedBytes: 2 * gb,
          availableBytes: 38 * gb,
          isPersistent: true,
        ),
      ),
    );
    expect(find.text(warning), findsNothing);

    await tester.pumpWidget(
      wrap(
        const StorageCapacity(
          usedBytes: 2 * gb,
          availableBytes: 38 * gb,
          isPersistent: false,
        ),
      ),
    );
    expect(find.text(warning), findsOneWidget);
  });
}
