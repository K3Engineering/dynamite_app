import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/firmware_release.dart';
import 'package:dynamite_app/screens/firmware_update_screen.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';
import 'package:dynamite_app/services/firmware_update_service.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/session_metadata.dart';

import 'helpers/mockble.dart';

/// Widget tests for the firmware update screen's overview states, against
/// [MockBlePlatform] (same harness family as settings_tab_test). The mock
/// device reports firmware `mock-1.0.0`.
/// A catalog serving a fixed list of releases, whatever the channel.
class _FixedCatalog implements FirmwareCatalog {
  new(this.releases);

  final List<FirmwareRelease> releases;

  @override
  Future<List<FirmwareRelease>> available() async => releases;

  @override
  Future<Uint8List> downloadImage(FirmwareRelease release) =>
      throw UnimplementedError('tests never download');
}

/// A catalog whose check always fails (fetch trouble).
class _ErrorCatalog implements FirmwareCatalog {
  @override
  Future<List<FirmwareRelease>> available() => throw StateError('fetch failed');

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

void main() {
  const deviceId = '2';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  Future<BleLinkManager> pump(
    WidgetTester tester, {
    required FirmwareCatalog catalog,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final prefs = await SharedPreferences.getInstance();
    final events = AppEvents();
    final hub = DataHub();
    final link = BleLinkManager(
      events: events,
      demo: DemoDevice(),
      onAdcData: (_) {},
      onSampleRate: (_) {},
      onDeviceFlash: (_) {},
    );
    final recording = RecordingController(
      dataHub: hub,
      streamingChanges: link,
      streamingNow: () => link.isStreaming,
      deviceMetadataSnapshot: () => toSessionDeviceMetadata(
        name: link.connectedDeviceName,
        info: link.connectedDeviceInfo!,
      ),
      deviceKvsSnapshot: () => null,
      onSessionBoundary: () {},
      events: events,
    );
    final service = FirmwareUpdateService(
      prefs: prefs,
      link: link,
      events: events,
      catalog: catalog,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BleLinkManager>.value(value: link),
          ChangeNotifierProvider<FirmwareUpdateService>.value(value: service),
          ChangeNotifierProvider<RecordingController>.value(value: recording),
        ],
        child: MaterialApp(home: FirmwareUpdateScreen(onDone: () {})),
      ),
    );
    // Drain the construction-time BLE timers (the mock's 200ms availability
    // query and universal_ble's 5s command-queue timeout) — same pattern as
    // settings_tab_test.
    await tester.pump(const Duration(seconds: 6));
    return link;
  }

  /// Connect the mock device and let its auto-check run.
  Future<void> connect(WidgetTester tester, BleLinkManager link) async {
    unawaited(link.connectToDevice(deviceId));
    await tester.pump(const Duration(seconds: 4));
  }

  /// A GATT link's disconnect awaits the mock's platform timers; drive it
  /// with pumps rather than awaiting it inside the test body.
  Future<void> disconnect(WidgetTester tester, BleLinkManager link) async {
    unawaited(link.disconnectSelectedDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  }

  OutlinedButton versionButton(WidgetTester tester) => tester.widget(
    find.widgetWithText(OutlinedButton, 'Choose another version…'),
  );

  testWidgets('no link: the version button renders anyway, disabled', (
    tester,
  ) async {
    await pump(tester, catalog: _FixedCatalog(const []));

    expect(find.text('Choose another version…'), findsOneWidget);
    expect(versionButton(tester).onPressed, isNull);
    expect(find.text('No device connected'), findsOneWidget);
  });

  testWidgets('empty catalog: the dialog explains instead of listing', (
    tester,
  ) async {
    final link = await pump(tester, catalog: _FixedCatalog(const []));
    await connect(tester, link);

    expect(find.text('No release published yet'), findsOneWidget);
    await tester.tap(find.text('Choose another version…'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a version'), findsOneWidget);
    expect(find.text('No flashable releases published yet.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await disconnect(tester, link);
  });

  testWidgets('failed check: loud hero, and the dialog names the failure', (
    tester,
  ) async {
    final link = await pump(tester, catalog: _ErrorCatalog());
    await connect(tester, link);

    expect(find.text('Could not check for updates'), findsOneWidget);
    expect(find.textContaining('fetch failed'), findsOneWidget);
    await tester.tap(find.text('Choose another version…'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No version list — the check failed.'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await disconnect(tester, link);
  });

  testWidgets('candidates present: the picker lists rows with the target', (
    tester,
  ) async {
    final link = await pump(
      tester,
      catalog: _FixedCatalog([_release('mock-1.0.0')]),
    );
    await connect(tester, link);

    expect(find.text('mock-1.0.0 - up to date'), findsOneWidget);
    await tester.tap(find.text('Choose another version…'));
    await tester.pumpAndSettle();
    expect(find.text('mock-1.0.0'), findsWidgets);
    expect(find.textContaining('channel target'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await disconnect(tester, link);
  });
}
