import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/firmware_release.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';
import 'package:dynamite_app/services/firmware_update_service.dart';
import 'package:dynamite_app/widgets/firmware_update_notice.dart';
import 'helpers/mockble.dart';

/// A catalog serving a fixed target, whatever the channel.
class _FixedCatalog implements FirmwareCatalog {
  _FixedCatalog(this.target);

  final FirmwareRelease? target;

  @override
  Future<FirmwareRelease?> latestFor({
    required FirmwareChannel channel,
  }) async => target;

  @override
  Future<Uint8List> downloadImage(FirmwareRelease release) =>
      throw UnimplementedError('tests never download');
}

FirmwareRelease _release(String tag) => FirmwareRelease(
  tag: tag,
  version: FirmwareVersion.tryParse(tag) ?? const FirmwareVersion(0, 0, 1),
  assetName: 'image.bin',
  size: 1,
  downloadUrl: Uri.parse('https://example.com/$tag.bin'),
  sha256Url: Uri.parse('https://example.com/$tag.sha256'),
);

/// The update notice renders straight off [FirmwareUpdateService.checkState]:
/// present (with the target tag) while the connected device's check differs,
/// gone once it matches — and tapping reviews.
void main() {
  const deviceId = '2';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  testWidgets('follows the check state and reviews on tap', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final events = AppEvents();
    final link = BleLinkManager(
      events: events,
      onDeviceFlash: (_) {},
      onAdcData: (_) {},
      onSampleRate: (_) {},
    );
    final service = FirmwareUpdateService(
      prefs: prefs,
      link: link,
      events: events,
      catalog: _FixedCatalog(_release('v0.2.0')),
    );
    var reviewed = false;

    await tester.pumpWidget(
      ChangeNotifierProvider<FirmwareUpdateService>.value(
        value: service,
        child: MaterialApp(
          home: Scaffold(
            body: FirmwareUpdateNotice(onReview: () => reviewed = true),
          ),
        ),
      ),
    );
    // Settle the mock's startup round-trips (see widget_test.dart).
    await tester.pump(const Duration(seconds: 6));

    // No check result yet: nothing renders.
    expect(find.textContaining('Firmware update available'), findsNothing);

    // Connect the mock device (reports mock-1.0.0 against target v0.2.0): the
    // background check differs and the line appears.
    unawaited(link.connectToDevice(deviceId));
    await tester.pump();
    for (var i = 0; i < 8 && !link.isStreaming; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(link.isStreaming, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Firmware update available · v0.2.0'), findsOneWidget);

    await tester.tap(find.text('Firmware update available · v0.2.0'));
    expect(reviewed, isTrue);

    // Point the catalog at the bits the device already runs and re-check
    // (UI-triggered checks always run): the line hides.
    service.catalog = _FixedCatalog(_release('mock-1.0.0'));
    unawaited(service.checkForUpdates());
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Firmware update available'), findsNothing);

    // Teardown: end the stream so its timers stop, then drain the mock's
    // disconnect + the command-queue timeout.
    unawaited(link.disconnectSelectedDevice());
    await tester.pump(const Duration(seconds: 8));
  });
}
