import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/firmware_release.dart';
import '../services/ble_link_manager.dart';
import '../services/firmware_update_service.dart';
import '../widgets/wide_layout.dart';

enum _Stage { overview, downloading, flashing, rebooting, done, failed }

/// The OTA update flow, pushed from the Settings tab's firmware card or
/// deep-linked from the update-available snackbar.
///
/// Offer rule (see `firmware_release.dart`): the device should run the
/// channel's target release, whatever the direction — "differs" flashes it,
/// including the same-tag reflash. The screen owns the flash stages
/// (download -> verify -> BLE transfer -> reboot -> verdict); the release
/// check itself lives in [FirmwareUpdateService].
class FirmwareUpdateScreen extends StatefulWidget {
  const FirmwareUpdateScreen({super.key});

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

  /// TODO double-check "several minutes"
  Future<void> _flashRelease(FirmwareRelease release) async {
    final confirmed = await _confirmFlash(
      'Flash ${release.tag} to this device?',
      'Keep the app open during the flashing process. The process typically takes several minutes. '
          'The device will reboot when done. Your settings will not be erased.',
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
      '${bytes.length} bytes. Keep the app open. The device reboots when done. ',
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
      _headline = 'Flashing - do not disconnect…';
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
            'Image accepted - the device is rebooting. Reconnect to it from '
            'the Devices tab.';
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
    final inProgress =
        _busy || _stage == _Stage.done || _stage == _Stage.failed;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Firmware update')),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final hPad = contentSideInset(constraints.maxWidth);
              if (inProgress) {
                // The flash page is a single moment of attention: centered
                // and narrow rather than stretched across a desktop window.
                return Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: hPad,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _buildProgress(),
                    ),
                  ),
                );
              }
              return ListView(
                padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 16),
                children: _buildOverview(
                  service,
                  simulated: simulated,
                  linkUp: linkUp,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _buildProgress() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_stage == _Stage.done) {
      return [
        Icon(Icons.check_circle_outline, color: scheme.primary, size: 48),
        const SizedBox(height: 16),
        Text(
          _result!,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ];
    }
    if (_stage == _Stage.failed) {
      return [
        Icon(Icons.error_outline, color: scheme.error, size: 48),
        const SizedBox(height: 16),
        Text(
          _error ?? 'Flash failed.',
          style: TextStyle(color: scheme.error),
          textAlign: TextAlign.center,
        ),
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
    final step = switch (_stage) {
      _Stage.downloading => 'Step 1 of 3, downloading',
      _Stage.flashing =>
        'Step 2 of 3, flashing · ${(_progress * 100).toStringAsFixed(0)}%',
      _Stage.rebooting => 'Step 3 of 3, rebooting',
      _ => '',
    };
    return [
      Text(
        _headline,
        style: theme.textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      LinearProgressIndicator(
        value: _stage == _Stage.flashing ? _progress : null,
      ),
      const SizedBox(height: 12),
      Text(step, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      Text(
        'Keep this page open while the firmware updates.',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
    ];
  }

  /// The headline of the overview card: installed -> target, or the plain
  /// state when there is no comparison to draw.
  String _heroLine(FirmwareUpdateService service, {required bool linkUp}) {
    final check = service.check;
    if (service.checking && check == null) return 'Checking…';
    if (check == null) {
      return linkUp ? 'No release check yet' : 'No device connected';
    }
    final target = check.target;
    if (target == null) return 'No release available for this board';
    return check.differsFromDevice
        ? '${check.installedDescribe}  →  ${target.tag}'
        : '${check.installedDescribe} - up to date';
  }

  List<Widget> _buildOverview(
    FirmwareUpdateService service, {
    required bool simulated,
    required bool linkUp,
  }) {
    final theme = Theme.of(context);
    final check = service.check;
    final target = check?.target;
    final canFlash = linkUp && !simulated && !service.checking;
    final flashLabel = target == null
        ? 'No release to flash'
        : check!.differsFromDevice
        ? 'Update to ${target.tag}'
        : 'Reflash ${target.tag}';

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _heroLine(service, linkUp: linkUp),
                style: theme.textTheme.titleLarge,
              ),
              if (check != null)
                Text('Board: ${check.board}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Text('Channel', style: theme.textTheme.titleSmall),
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
              if (service.checking && check != null)
                const Text('Checking…')
              else if (service.checkError != null)
                Text(
                  'Check failed: ${service.checkError}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: canFlash && target != null
                    ? () => unawaited(_flashRelease(target))
                    : null,
                child: Text(flashLabel),
              ),
              if (simulated)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Firmware update is unavailable for the demo device.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('Developer', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(
            onPressed: canFlash ? () => unawaited(_flashFromFile()) : null,
            child: const Text('Flash image from file…'),
          ),
        ),
      ),
    ];
  }
}
