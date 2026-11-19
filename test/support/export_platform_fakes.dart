import 'dart:typed_data';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

class TestFilePickerPlatform extends FilePickerPlatform {
  late String fileName;
  late Uint8List bytes;
  late String mimeType;
  String? dialogTitle;
  Uri? result;

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
    return result;
  }
}

class TestPathProviderPlatform extends PathProviderPlatform {
  new(this.cachePath);

  final String cachePath;

  @override
  Future<String?> getApplicationCachePath() async => cachePath;
}

class RecordingSharePlatform extends SharePlatform {
  final calls = <ShareParams>[];
  ShareResultStatus status = ShareResultStatus.dismissed;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls.add(params);
    return ShareResult('', status);
  }
}
