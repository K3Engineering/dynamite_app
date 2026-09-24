import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/firmware_release.dart';
import '../services/ble_link_manager.dart';
import '../services/firmware_update_service.dart';
import '../widgets/wide_layout.dart';

/// The update flow's page state. Each payload stage carries the data its
/// page renders, so there is no "failed with no error" or "flashing with a
/// stale progress" state.
sealed class _Stage {
  const _Stage();
}

/// Pick-a-release view; also where the failure page's Back button returns.
final class _Overview extends _Stage {
  const _Overview();
}

/// Image download in flight; [headline] names the asset so the page reads
/// "Downloading foo.bin…".
final class _Downloading extends _Stage {
  const _Downloading(this.headline);

  final String headline;
}

/// Transfer to the device in flight. [progress] mutates in place; the
/// progress callback re-reads it via setState.
final class _Flashing extends _Stage {
  _Flashing();

  double progress = 0;
}

/// Image accepted; the device reboots on its own.
final class _Done extends _Stage {
  const _Done();
}

/// Flash failed; [error] is the thrown error, shown verbatim.
final class _Failed extends _Stage {
  const _Failed(this.error);

  final String error;
}

/// The OTA update flow, pushed from the Settings firmware card or the
/// update-available snackbar.
///
/// Offer rule (see `firmware_release.dart`): the device should run the
/// channel's target whatever the direction — "differs" flashes it, same-tag
/// included. This screen owns the flash stages (download -> transfer); the
/// check lives in [FirmwareUpdateService]. An accepted image ends at the done
/// banner (the device reboots on its own, so no modal state past the transfer);
/// a taken flash is confirmed by the next check's [FirmwareFlashVerified], one
/// that didn't re-flags the banner.
class FirmwareUpdateScreen extends StatefulWidget {
  const FirmwareUpdateScreen({super.key, required this.onDone});

  /// Where "Done" goes once the screen pops: the app shell's Devices-tab
  /// jump. The device reboots into the flashed image, so the user re-finds
  /// it in the device list.
  final VoidCallback onDone;

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  late final BleLinkManager _link = context.read<BleLinkManager>();
  late final FirmwareUpdateService _updates = context
      .read<FirmwareUpdateService>();

  _Stage _stage = const _Overview();

  bool get _busy => _stage is _Downloading || _stage is _Flashing;

  @override
  void initState() {
    super.initState();
    if (_updates.checkState is CheckNeverRan) {
      unawaited(_updates.checkForUpdates());
    }
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
      _stage = _Downloading('Downloading ${release.assetName}…');
    });
    Uint8List image;
    try {
      image = await _updates.catalog.downloadImage(release);
    } catch (e) {
      setState(() {
        _stage = _Failed('$e');
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
    final flashing = _Flashing();
    setState(() {
      _stage = flashing;
    });
    _updates.flashInProgress.value = true;
    try {
      await _link.runOta(
        (client) => client.flash(
          image: image,
          onProgress: (sent) {
            if (mounted) {
              setState(() => flashing.progress = sent / image.length);
            }
          },
        ),
      );
      if (!mounted) return;
      final tag = flashedTag;
      if (tag != null) _updates.noteFlashAccepted(tag);
      setState(() => _stage = const _Done());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Failed('$e');
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
    final inProgress = _stage is! _Overview;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          // A blocked pop that looks tappable reads as a dead button.
          // BackButton(onPressed: null) is not disabled — null means "use
          // Navigator.maybePop", so the disabled state needs a plain
          // IconButton.
          leading: _busy
              ? const IconButton(icon: BackButtonIcon(), onPressed: null)
              : null,
          title: const Text('Firmware update'),
        ),
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

  /// The in-progress page for the current stage (only called off the
  /// overview page).
  List<Widget> _buildProgress() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    switch (_stage) {
      case _Done():
        return [
          Icon(Icons.check_circle_outline, color: scheme.secondary, size: 48),
          const SizedBox(height: 16),
          Text(
            'Image accepted — the device is rebooting. It should be back on '
            'the Devices tab in a few seconds.',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDone();
            },
            child: const Text('Done'),
          ),
        ];
      case _Failed(:final error):
        return [
          Icon(Icons.error_outline, color: scheme.error, size: 48),
          const SizedBox(height: 16),
          Text(
            error,
            style: TextStyle(color: scheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => setState(() => _stage = const _Overview()),
            child: const Text('Back'),
          ),
        ];
      case _Downloading(:final headline):
        return _transferPage(headline, 'Step 1 of 2, downloading', null);
      case _Flashing(:final progress):
        return _transferPage(
          'Flashing - do not disconnect…',
          'Step 2 of 2, flashing · ${(progress * 100).toStringAsFixed(0)}%',
          progress,
        );
      case _Overview():
        throw StateError('overviews never reach the progress page');
    }
  }

  /// The transfer page shared by [_Downloading] and [_Flashing]: headline,
  /// progress bar ([value] null = indeterminate), step caption.
  List<Widget> _transferPage(String headline, String step, double? value) {
    final theme = Theme.of(context);
    return [
      Text(
        headline,
        style: theme.textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      // explicit track: the scheme's secondaryContainer declares no
      // separate tonal container (see main.dart), and the M3 default track
      // reads that role — identical to the fill here.
      LinearProgressIndicator(
        value: value,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      const SizedBox(height: 12),
      Text(step, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      Text(
        'Keep this page open while the firmware transfers.',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
    ];
  }

  /// The headline of the overview card: installed -> target, or the plain
  /// state when there is no comparison to draw.
  String _heroLine(FirmwareUpdateService service, {required bool linkUp}) {
    switch (service.checkState) {
      case CheckNeverRan():
        return linkUp ? 'No release check yet' : 'No device connected';
      case CheckRunning():
        return 'Checking…';
      case CheckFailed():
        return 'Could not check for updates';
      case CheckOk(:final result):
        final target = result.target;
        if (target == null) return 'No release available for this board';
        return result.differsFromDevice
            ? '${result.installedDescribe}  →  ${target.tag}'
            : '${result.installedDescribe} - up to date';
    }
  }

  List<Widget> _buildOverview(
    FirmwareUpdateService service, {
    required bool simulated,
    required bool linkUp,
  }) {
    final theme = Theme.of(context);
    final state = service.checkState;
    final check = state is CheckOk ? state.result : null;
    final target = check?.target;
    final running = state is CheckRunning;
    final canFlash = linkUp && !simulated && !running;
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
                onSelectionChanged: running
                    ? null
                    : (set) => unawaited(service.setChannel(set.first)),
              ),
              const SizedBox(height: 16),
              if (state is CheckFailed)
                Text(
                  'Check failed: ${state.error}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: running || !linkUp
                    ? null
                    : () => unawaited(service.checkForUpdates()),
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
