import 'dart:io';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:dynamite_app/services/export_delivery.dart';

import 'support/export_platform_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const anchor = (left: 1.0, top: 2.0, width: 2.0, height: 2.0);
  final originalFilePicker = FilePickerPlatform.instance;
  final originalPathProvider = PathProviderPlatform.instance;
  final originalSharePlatform = SharePlatform.instance;
  // SharePlus.instance captures SharePlatform.instance on first use. Install
  // one recording platform before that read, then reset it for every test.
  final sharePlatform = RecordingSharePlatform();
  SharePlatform.instance = sharePlatform;
  late TestFilePickerPlatform filePicker;
  late Directory temp;

  tearDownAll(() => SharePlatform.instance = originalSharePlatform);

  ExportArtifact newArtifact(List<int> bytes) => (
    bytes: Uint8List.fromList(bytes),
    fileName: 'session.csv',
    mimeType: 'text/csv',
  );
  Future<String?> performShare(List<int> bytes) =>
      shareExport(newArtifact(bytes), dialogTitle: 'Share CSV', anchor: anchor);
  Directory exportCache() => Directory('${temp.path}/dynamite_exports');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('export_delivery_test');
    filePicker = TestFilePickerPlatform();
    sharePlatform.reset();
    FilePickerPlatform.instance = filePicker;
    PathProviderPlatform.instance = TestPathProviderPlatform(temp.path);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    FilePickerPlatform.instance = originalFilePicker;
    PathProviderPlatform.instance = originalPathProvider;
    temp.deleteSync(recursive: true);
  });

  test(
    'downloadExport forwards the complete artifact to file_picker',
    () async {
      final artifact = newArtifact([1, 2, 3]);

      final result = await downloadExport(
        artifact,
        dialogTitle: 'Download session CSV',
      );

      expect(result, isNull);
      expect(filePicker.fileName, 'session.csv');
      expect(filePicker.bytes, same(artifact.bytes));
      expect(filePicker.mimeType, 'text/csv');
      expect(filePicker.dialogTitle, 'Download session CSV');
    },
  );

  test('downloadExport formats the native file Uri as a local path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    filePicker.result = Uri.file(r'C:\Temp\my session.csv', windows: true);

    final result = await downloadExport(
      newArtifact([1]),
      dialogTitle: 'Download session CSV',
    );

    expect(result, r'Saved to C:\Temp\my session.csv');
    expect(result, isNot(contains('%20')));
  });

  test('downloadExport keeps non-file URIs intact', () async {
    filePicker.result = Uri.parse('content://exports/session%20report.csv');

    final result = await downloadExport(
      newArtifact([1]),
      dialogTitle: 'Download session CSV',
    );

    expect(result, 'Saved to content://exports/session%20report.csv');
  });

  test(
    'native shares keep independent app-cache files after completing',
    () async {
      await performShare([1, 2, 3]);
      await performShare([4, 5, 6]);

      final paths = [
        for (final call in sharePlatform.calls) call.files!.single.path,
      ];
      expect(paths[0], isNot(paths[1]));
      expect(paths[0], startsWith(exportCache().path));
      expect(paths[1], startsWith(exportCache().path));
      expect(File(paths[0]).readAsBytesSync(), [1, 2, 3]);
      expect(File(paths[1]).readAsBytesSync(), [4, 5, 6]);
      for (final call in sharePlatform.calls) {
        expect(call.files!.single.mimeType, 'text/csv');
        expect(call.fileNameOverrides, ['session.csv']);
        expect(call.downloadFallbackEnabled, isFalse);
        expect(call.sharePositionOrigin, const Rect.fromLTWH(1, 2, 2, 2));
      }
    },
  );

  test('shareExport reports every plugin result status', () async {
    for (final (status, expected) in [
      (ShareResultStatus.success, 'Shared session.csv'),
      (ShareResultStatus.dismissed, null),
      (ShareResultStatus.unavailable, 'Shared session.csv (status unknown)'),
    ]) {
      sharePlatform.status = status;
      await expectLater(performShare([1]), completion(expected));
    }
  });

  testWidgets(
    'shareDelivery uses the invoking widget full bounds at delivery',
    (tester) async {
      final key = GlobalKey();
      Widget host(double left) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(left: left, top: 30),
              child: SizedBox(key: key, width: 100, height: 50),
            ),
          ),
        ),
      );

      await tester.pumpWidget(host(20));
      final delivery = shareDelivery('Share CSV');
      await tester.pumpWidget(host(40));
      // Native temp-file I/O needs the real event loop, not fake-async pumping.
      await tester.runAsync(
        () => delivery(key.currentContext!, newArtifact([1])),
      );

      expect(
        sharePlatform.calls.single.sharePositionOrigin,
        const Rect.fromLTWH(40, 30, 100, 50),
      );
    },
  );

  testWidgets('shareAnchorFor clips a partially visible source', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 580),
            child: SizedBox(key: key, width: 100, height: 50),
          ),
        ),
      ),
    );

    expect(shareAnchorFor(key.currentContext!), (
      left: 0.0,
      top: 580.0,
      width: 100.0,
      height: 20.0,
    ));
  });

  testWidgets('shareAnchorFor centers an invisible source', (tester) async {
    final key = GlobalKey();
    Widget host(double top, double size) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: SizedBox(key: key, width: size, height: size),
        ),
      ),
    );
    const centered = (left: 399.0, top: 299.0, width: 2.0, height: 2.0);

    await tester.pumpWidget(host(700, 100));
    expect(shareAnchorFor(key.currentContext!), centered);

    await tester.pumpWidget(host(30, 0));
    expect(shareAnchorFor(key.currentContext!), centered);
  });
}
