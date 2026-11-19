import 'dart:io';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:dynamite_app/services/export_delivery.dart';

class _RecordingFilePicker extends FilePickerPlatform {
  String? fileName;
  Uint8List? bytes;
  String? mimeType;
  String? dialogTitle;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    void Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.fileName = fileName;
    this.bytes = bytes;
    this.mimeType = mimeType;
    this.dialogTitle = dialogTitle;
    return null;
  }
}

class _RecordingSharePlatform extends SharePlatform {
  final calls = <ShareParams>[];

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls.add(params);
    return const ShareResult('', ShareResultStatus.dismissed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const anchor = (left: 1.0, top: 2.0, width: 2.0, height: 2.0);
  final originalFilePicker = FilePickerPlatform.instance;
  final originalSharePlatform = SharePlatform.instance;
  final filePicker = _RecordingFilePicker();
  final sharePlatform = _RecordingSharePlatform();
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('export_delivery_test');
    FilePickerPlatform.instance = filePicker;
    SharePlatform.instance = sharePlatform;
    sharePlatform.calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return call.method == 'getTemporaryDirectory' ? temp.path : null;
        });
  });

  tearDown(() {
    FilePickerPlatform.instance = originalFilePicker;
    SharePlatform.instance = originalSharePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    temp.deleteSync(recursive: true);
  });

  test(
    'downloadExport forwards the complete artifact to file_picker',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);

      final result = await downloadExport((
        bytes: bytes,
        fileName: 'session.csv',
        mimeType: 'text/csv',
      ), dialogTitle: 'Download session CSV');

      expect(result, isNull);
      expect(filePicker.fileName, 'session.csv');
      expect(filePicker.bytes, same(bytes));
      expect(filePicker.mimeType, 'text/csv');
      expect(filePicker.dialogTitle, 'Download session CSV');
    },
  );

  test(
    'native shares keep independent files after their futures complete',
    () async {
      Future<void> share(List<int> bytes) => shareExport(
        (
          bytes: Uint8List.fromList(bytes),
          fileName: 'session.csv',
          mimeType: 'text/csv',
        ),
        dialogTitle: 'Share CSV',
        anchor: anchor,
      );

      await share([1, 2, 3]);
      await share([4, 5, 6]);

      final paths = [
        for (final call in sharePlatform.calls) call.files!.single.path,
      ];
      expect(paths[0], isNot(paths[1]));
      expect(File(paths[0]).readAsBytesSync(), [1, 2, 3]);
      expect(File(paths[1]).readAsBytesSync(), [4, 5, 6]);
      for (final call in sharePlatform.calls) {
        expect(call.files!.single.mimeType, 'text/csv');
        expect(call.fileNameOverrides, ['session.csv']);
      }
    },
  );

  testWidgets('shareDelivery reads the anchor at delivery time', (
    tester,
  ) async {
    final key = GlobalKey();
    Widget host(double left) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: left, top: 30),
          child: SizedBox(key: key, width: 100, height: 50),
        ),
      ),
    );

    await tester.pumpWidget(host(20));
    final delivery = shareDelivery('Share CSV', key.currentContext!);
    await tester.pumpWidget(host(40));
    // Native temp-file I/O needs the real event loop, not fake-async pumping.
    await tester.runAsync(
      () => delivery((
        bytes: Uint8List.fromList([1]),
        fileName: 'session.csv',
        mimeType: 'text/csv',
      )),
    );

    // The center of the repositioned render box, not its full bounds or the
    // position it had when the delivery closure was created.
    expect(
      sharePlatform.calls.single.sharePositionOrigin,
      const Rect.fromLTWH(89, 54, 2, 2),
    );
  });
}
