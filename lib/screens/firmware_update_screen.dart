import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/firmware_release.dart';
import '../services/ble_link_manager.dart';
import '../services/firmware_update_service.dart';

enum _Stage { overview, downloading, flashing, rebooting, done, failed }

/// The OTA update flow, pushed from the Settings tab's firmware card.
///
/// Offer rule (see `firmware_release.dart`): the device should run the
/// channel's target release, whatever the direction — "differs" flashes it,
/// including the same-tag reflash. The screen owns the flash stages
/// (download -> verify -> BLE transfer -> reboot -> verdict); the release
/// check itself lives in [FirmwareUpdateService].
class FirmwareUpdateScreen extends StatefulWidget {
  const FirmwareUpdateScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  late final BleLinkManager _link = context.read<BleLinkManager>();
  late final FirmwareUpdateService _updates = context
      .read<FirmwareUpdateService>();

  _Stage _stage = _Stage.overview;
  double _progress = 0;
  String _headline = '';
  String? _error;

  /// The tag we just flashed, for the post-reboot verdict; null after a
  /// from-file flash (no identity to compare, the verdict just reports).
  String? _flashedTag;
  String? _result;

  bool get _busy =>
      _stage == _Stage.downloading ||
      _stage == _Stage.flashing ||
      _stage == _Stage.rebooting;

  @override
  void initState() {
    super.initState();
    _link.addListener(_onLinkChanged);
    if (_updates.check == null && !_updates.checking) {
      unawaited(_updates.checkForUpdates());
    }
  }

  @override
  void dispose() {
    _link.removeListener(_onLinkChanged);
    super.dispose();
  }

  /// Post-reboot verdict: a fresh DIS identity read means the device came
  /// back (the user re-connected it). Compare its describe to the tag we
  /// flashed; a mismatch means the bootloader rolled back or the flash
  /// never took effect.
  void _onLinkChanged() {
    if (_stage != _Stage.rebooting || !mounted) return;
    final rev = _link.connectedDeviceInfo?.firmwareRev;
    if (rev == null) return;
    final parsed = parseFirmwareRev(rev);
    if (parsed == null) return;
    final expected = _flashedTag;
    setState(() {
      _stage = _Stage.done;
      _result =
          expected == null || describeMatchesTag(parsed.describe, expected)
          ? 'Now running ${parsed.describe}.'
          : 'The device still runs ${parsed.describe} — the update was '
                'rolled back or never applied.';
    });
  }

  Future<void> _flashRelease(FirmwareRelease release) async {
    final confirmed = await _confirmFlash(
      'Flash ${release.tag} to this device?',
      'The current link will be used. The data feed pauses during the '
          'transfer and the device reboots when done — keep the app open.',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _stage = _Stage.downloading;
      _headline = 'Downloading ${release.assetName}…';
      _progress = 0;
    });
    Uint8List image;
    try {
      image = await _updates.catalog.downloadImage(release);
    } catch (e) {
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
      return;
    }
    await _flash(image, flashedTag: release.tag);
  }

  Future<void> _flashFromFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    if (!mounted || file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final confirmed = await _confirmFlash(
      'Flash ${file.name}?',
      '${bytes.length} bytes. The device reboots when done — keep the app '
          'open.',
    );
    if (!confirmed || !mounted) return;
    await _flash(bytes, flashedTag: null);
  }

  Future<bool> _confirmFlash(String title, String body) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Flash'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _flash(Uint8List image, {required String? flashedTag}) async {
    setState(() {
      _stage = _Stage.flashing;
      _headline = 'Flashing — do not disconnect…';
      _progress = 0;
    });
    _flashedTag = flashedTag;
    _updates.flashInProgress.value = true;
    try {
      await _link.runOta(
        (client) => client.flash(
          image: image,
          onProgress: (sent) {
            if (mounted) setState(() => _progress = sent / image.length);
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _stage = _Stage.rebooting;
        _headline =
            'Image accepted — the device is rebooting. Reconnect it from '
            'the Devices tab to confirm the version.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
    } finally {
      _updates.flashInProgress.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FirmwareUpdateService>();
    final simulated = context.select<BleLinkManager, bool>(
      (l) => l.linkIsSimulated,
    );
    final linkUp = context.select<BleLinkManager, bool>(
      (l) => l.connectedDeviceId.isNotEmpty,
    );

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Firmware update')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: _busy || _stage == _Stage.done || _stage == _Stage.failed
                ? _buildProgress()
                : _buildOverview(service, simulated: simulated, linkUp: linkUp),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildProgress() {
    final scheme = Theme.of(context).colorScheme;
    if (_stage == _Stage.done) {
      return [
        Text(_result!, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ];
    }
    if (_stage == _Stage.failed) {
      return [
        Icon(Icons.error_outline, color: scheme.error, size: 40),
        const SizedBox(height: 12),
        Text(_error ?? 'Flash failed.', style: TextStyle(color: scheme.error)),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => setState(() {
            _stage = _Stage.overview;
            _error = null;
          }),
          child: const Text('Back'),
        ),
      ];
    }
    return [
      Text(_headline, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      LinearProgressIndicator(
        value: _stage == _Stage.flashing ? _progress : null,
      ),
      const SizedBox(height: 12),
      Text(
        _stage == _Stage.flashing
            ? '${(_progress * 100).toStringAsFixed(0)}%'
            : 'This takes a couple of minutes. Going back is blocked.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  List<Widget> _buildOverview(
    FirmwareUpdateService service, {
    required bool simulated,
    required bool linkUp,
  }) {
    final check = service.check;
    final target = check?.target;
    final canFlash = linkUp && !simulated && !service.checking;
    final flashLabel = target == null
        ? null
        : check!.differsFromDevice
        ? 'Flash ${target.tag}'
        : 'Reflash ${target.tag}';

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Installed', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                check?.installedDescribe ?? '—',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (check != null)
                Text(
                  'Board: ${check.board}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 16),
              Text('Channel', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<FirmwareChannel>(
                segments: [
                  for (final c in FirmwareChannel.values)
                    ButtonSegment(value: c, label: Text(c.label)),
                ],
                selected: {service.channel},
                showSelectedIcon: false,
                onSelectionChanged: (set) =>
                    unawaited(service.setChannel(set.first)),
              ),
              const SizedBox(height: 16),
              Text(
                'Channel target',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              if (service.checking)
                const Text('Checking…')
              else if (service.checkError != null)
                Text(
                  'Check failed: ${service.checkError}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                Text(target?.tag ?? 'No release available for this board yet.'),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: service.checking || !linkUp
                    ? null
                    : () => unawaited(service.checkForUpdates(manual: true)),
                child: const Text('Check now'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (simulated)
        const Text('Firmware update is unavailable for the demo device.'),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: canFlash && target != null
              ? () => unawaited(_flashRelease(target))
              : null,
          child: Text(flashLabel ?? 'No release to flash'),
        ),
      ),
      const SizedBox(height: 24),
      Text('Developer', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: canFlash ? () => unawaited(_flashFromFile()) : null,
          child: const Text('Flash image from file…'),
        ),
      ),
    ];
  }
}
