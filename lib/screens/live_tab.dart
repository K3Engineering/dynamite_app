import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import 'package:drift/drift.dart' show Value;
import 'package:google_fonts/google_fonts.dart';

import '../services/bt_handling.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../screens/app_shell.dart';
import '../widgets/graph_components.dart';

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

class GraphController extends ChangeNotifier {
  /// Start of visible window in samples.
  int _viewStart = 0;
  int get viewStart => _viewStart;

  /// End of visible window in samples. Null means "follow live edge".
  int? _viewEnd;
  int? get viewEnd => _viewEnd;

  /// Whether we're following the live edge (auto-scroll with new data).
  bool _isLive = true;
  bool get isLive => _isLive;

  /// When in live mode and zoomed in, this is the fixed span to show
  /// from the right edge. Null means "show all data from _viewStart".
  int? _liveSpan;

  /// Snap to live mode -- follow the right edge at current zoom level.
  void goLive() {
    if (_viewEnd != null) {
      _liveSpan = _viewEnd! - _viewStart;
    }
    _isLive = true;
    _viewEnd = null;
    notifyListeners();
  }

  /// Snap to live mode showing all data (fully zoomed out).
  void goLiveFullView() {
    _viewStart = 0;
    _viewEnd = null;
    _liveSpan = null;
    _isLive = true;
    notifyListeners();
  }

  /// Set a specific visible window (exits live mode).
  void setWindow(int start, int end) {
    _viewStart = math.max(0, start);
    _viewEnd = end;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Get the effective visible range given total data size.
  (int start, int end) effectiveRange(int totalSamples) {
    if (_isLive || _viewEnd == null) {
      if (_liveSpan != null && _liveSpan! < totalSamples) {
        // Zoomed-in live mode: show last _liveSpan samples
        return (totalSamples - _liveSpan!, totalSamples);
      }
      // Full-width live mode
      return (0, totalSamples);
    }
    return (_viewStart, _viewEnd!.clamp(_viewStart + 1, totalSamples));
  }

  /// Pan by a delta in samples (negative = left, positive = right).
  void pan(int deltaSamples, int totalSamples) {
    final (s, e) = effectiveRange(totalSamples);
    final span = e - s;
    int newStart = s + deltaSamples;
    int newEnd = newStart + span;

    // Clamp to valid range
    if (newStart < 0) {
      newStart = 0;
      newEnd = span;
    }
    if (newEnd >= totalSamples) {
      // Snap to live if we pan to the right edge
      _liveSpan = span < totalSamples ? span : null;
      _viewStart = math.max(0, totalSamples - span);
      _viewEnd = null;
      _isLive = true;
      notifyListeners();
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Zoom by a factor around a focal point (0.0 = left edge, 1.0 = right edge).
  void zoom(double factor, double focalFraction, int totalSamples) {
    final (s, e) = effectiveRange(totalSamples);
    final span = e - s;
    final newSpan = (span / factor).round().clamp(
      // Minimum ~50 samples visible (50ms at 1kHz)
      50,
      totalSamples,
    );

    final focal = s + (focalFraction * span).round();
    int newStart = focal - (focalFraction * newSpan).round();
    int newEnd = newStart + newSpan;

    if (newStart < 0) {
      newStart = 0;
      newEnd = newSpan;
    }
    if (newEnd >= totalSamples) {
      // At the right edge -- enter live mode with this span
      _liveSpan = newSpan < totalSamples ? newSpan : null;
      _viewStart = math.max(0, totalSamples - newSpan);
      _viewEnd = null;
      _isLive = true;
      notifyListeners();
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Reset to show all data in live mode (fully zoomed out).
  void reset() {
    _viewStart = 0;
    _viewEnd = null;
    _liveSpan = null;
    _isLive = true;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveMinimapDataSource implements MinimapDataSource {
  final DataHub _hub;
  _LiveMinimapDataSource(this._hub);

  @override
  int get sampleCount => _hub.rawSz;

  @override
  List<int> getChannelData(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return [];
    return _hub.rawData[lineIdx];
  }

  @override
  double getChannelMin(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.rawMin[lineIdx].toDouble();
  }

  @override
  double getChannelMax(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.rawMax[lineIdx].toDouble();
  }

  @override
  double getChannelTare(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.tare[lineIdx];
  }
}

class _LiveTabState extends State<LiveTab> {
  final GraphController _graphCtrl = GraphController();
  bool _showDerivative = false;

  // Gesture tracking
  double? _panStartX;
  int? _panStartSample;
  int? _panEndSample;
  double? _scaleStartSpan;
  double? _pinchFocalX;

  @override
  void dispose() {
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    final bt = context.read<BluetoothHandling>();
    bt.dataHub.requestTare();
  }

  Future<void> _onToggleRecord() async {
    final bt = context.read<BluetoothHandling>();
    if (bt.sessionInProgress) {
      bt.stopSession();

      // Auto-save if there's recorded data
      final recordedSamples = bt.dataHub.rawSz - bt.dataHub.recordingStartIdx;
      if (recordedSamples > 0) {
        final settings = context.read<AppSettings>();
        final now = DateTime.now();
        final autoName =
            '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

        try {
          final id = await SessionStorage.saveSession(
            dataHub: bt.dataHub,
            name: autoName,
            channelLabels: settings.channelLabels,
            channelCount: settings.activeChannelCount,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Session saved'),
                action: SnackBarAction(
                  label: 'Name it',
                  onPressed: () => _showRenameDialog(id, autoName),
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
          }
        }
      }
    } else {
      // toggleSession marks the recording start index inside DataHub.
      bt.toggleSession();
    }
  }

  Future<void> _showRenameDialog(int sessionId, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Session name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      await AppDatabase.instance.updateSession(
        sessionId,
        SessionsCompanion(name: Value(newName)),
      );
    }
    controller.dispose();
  }

  // -- Gesture handlers for zoom/pan --

  void _onScaleStart(ScaleStartDetails details) {
    final bt = context.read<BluetoothHandling>();
    final total = bt.dataHub.rawSz;
    if (total == 0) return;

    final (s, e) = _graphCtrl.effectiveRange(total);
    _panStartSample = s;
    _panEndSample = e;
    _panStartX = details.localFocalPoint.dx;
    _scaleStartSpan = (e - s).toDouble();
    _pinchFocalX = details.localFocalPoint.dx;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    final bt = context.read<BluetoothHandling>();
    final total = bt.dataHub.rawSz;
    if (total == 0 || _panStartSample == null || graphWidth <= 0) return;

    final origStart = _panStartSample!;
    final origEnd = _panEndSample!;
    final origSpan = origEnd - origStart;

    if (details.scale != 1.0 && _scaleStartSpan != null) {
      // Pinch zoom
      final newSpan = (_scaleStartSpan! / details.scale).round().clamp(
        50,
        total,
      );

      // Focal point as fraction of graph width
      final focalFrac = (_pinchFocalX! / graphWidth).clamp(0.0, 1.0);
      final focalSample = origStart + (focalFrac * origSpan).round();

      int newStart = focalSample - (focalFrac * newSpan).round();
      int newEnd = newStart + newSpan;

      if (newStart < 0) {
        newStart = 0;
        newEnd = newSpan;
      }
      if (newEnd >= total) {
        newEnd = total;
        newStart = math.max(0, total - newSpan);
      }

      _graphCtrl.setWindow(newStart, newEnd);
      if (newEnd >= total) _graphCtrl.goLive();
    } else {
      // Pan
      final dx = details.localFocalPoint.dx - _panStartX!;
      final samplesPerPixel = origSpan / graphWidth;
      final deltaSamples = -(dx * samplesPerPixel).round();

      int newStart = origStart + deltaSamples;
      int newEnd = newStart + origSpan;

      if (newStart < 0) {
        newStart = 0;
        newEnd = origSpan;
      }
      if (newEnd >= total) {
        newEnd = total;
        newStart = math.max(0, total - origSpan);
        _graphCtrl.setWindow(newStart, newEnd);
        _graphCtrl.goLive();
        return;
      }

      _graphCtrl.setWindow(newStart, newEnd);
    }
  }

  void _onPointerSignal(PointerSignalEvent event, double graphWidth) {
    if (event is PointerScrollEvent) {
      final bt = context.read<BluetoothHandling>();
      final total = bt.dataHub.rawSz;
      if (total == 0 || graphWidth <= 0) return;

      // Scroll wheel zooms; focal point is mouse position (accounting for left margin)
      final focalFrac = ((event.localPosition.dx - 8.0) / graphWidth).clamp(
        0.0,
        1.0,
      );
      final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
      _graphCtrl.zoom(zoomFactor, focalFrac, total);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bt = context.watch<BluetoothHandling>();
    final isConnected = bt.isSubscribed;

    return SafeArea(
      child: Column(
        children: [
          LiveStatusBar(
            isConnected: isConnected,
            connectedDeviceName: bt.connectedDeviceName,
          ),
          if (isConnected)
            LiveStats(
              settings: settings,
              hub: bt.dataHub,
              showDerivative: _showDerivative,
            ),
          if (isConnected)
            Expanded(child: _buildGraphArea(bt, settings))
          else
            const Expanded(child: DisconnectedPrompt()),
          if (isConnected)
            ChannelLegend(
              settings: settings,
              showDerivative: _showDerivative,
              onToggleDerivative: () =>
                  setState(() => _showDerivative = !_showDerivative),
            ),
          if (isConnected)
            ActionButtons(
              isRecording: bt.sessionInProgress,
              onToggleRecord: _onToggleRecord,
              onTare: _onTare,
            ),
        ],
      ),
    );
  }

  Widget _buildGraphArea(BluetoothHandling bt, AppSettings settings) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth =
            constraints.maxWidth - 8 - 56; // leftSpace + rightSpace
        return Stack(
          children: [
            Column(
              children: [
                // Main force graph
                Expanded(
                  flex: _showDerivative ? 6 : 10,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: (e) => _onPointerSignal(e, graphWidth),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: (d) => _onScaleUpdate(d, graphWidth),
                      child: ListenableBuilder(
                        listenable: _graphCtrl,
                        builder: (context, _) => CustomPaint(
                          foregroundPainter: _LiveGraphPainter(
                            bt.dataHub,
                            settings,
                            _graphCtrl,
                            showXLabels: !_showDerivative,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  ),
                ),
                // Derivative graph (when enabled)
                if (_showDerivative)
                  Expanded(
                    flex: 4,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerSignal: (e) => _onPointerSignal(e, graphWidth),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: (d) => _onScaleUpdate(d, graphWidth),
                        child: ListenableBuilder(
                          listenable: _graphCtrl,
                          builder: (context, _) => CustomPaint(
                            foregroundPainter: _DerivativeGraphPainter(
                              bt.dataHub,
                              settings,
                              _graphCtrl,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Minimap
                ListenableBuilder(
                  listenable: bt.dataHub,
                  builder: (context, _) => Minimap(
                    dataSource: _LiveMinimapDataSource(bt.dataHub),
                    activeChannels: settings.activeChannelIndices,
                    graphCtrl: _graphCtrl,
                    channelColors: settings.activeChannelIndices
                        .map((i) => _channelColor(i))
                        .toList(),
                  ),
                ),
              ],
            ),
            // LIVE button (appears when not following live edge)
            ListenableBuilder(
              listenable: _graphCtrl,
              builder: (context, _) {
                if (_graphCtrl.isLive || bt.dataHub.rawSz == 0) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 64,
                  top: 8,
                  child: FilledButton.tonalIcon(
                    onPressed: _graphCtrl.goLiveFullView,
                    icon: const Icon(Icons.fast_forward, size: 16),
                    label: const Text('LIVE'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                );
              },
            ),
            // Zoom buttons
            Positioned(
              right: 8,
              bottom: 40,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'liveZoomIn',
                    onPressed: () {
                      if (bt.dataHub.rawSz > 0) {
                        _graphCtrl.zoom(1.2, 0.5, bt.dataHub.rawSz);
                      }
                    },
                    child: const Icon(Icons.zoom_in),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'liveZoomOut',
                    onPressed: () {
                      if (bt.dataHub.rawSz > 0) {
                        _graphCtrl.zoom(1 / 1.2, 0.5, bt.dataHub.rawSz);
                      }
                    },
                    child: const Icon(Icons.zoom_out),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStatusBar
// ---------------------------------------------------------------------------

class LiveStatusBar extends StatelessWidget {
  final bool isConnected;
  final String connectedDeviceName;

  const LiveStatusBar({
    super.key,
    required this.isConnected,
    required this.connectedDeviceName,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isConnected
          ? null
          : () {
              // Navigate to Devices tab
              final shell = context.findAncestorStateOfType<AppShellState>();
              shell?.switchToTab(2);
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: isConnected
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: [
            Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              size: 18,
              color: isConnected
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isConnected
                    ? 'Connected: $connectedDeviceName'
                    : 'Not connected \u2014 tap to connect',
                style: TextStyle(
                  color: isConnected
                      ? Theme.of(context).colorScheme.onPrimaryContainer
                      : Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (isConnected)
              Text(
                '${DataHub.samplesPerSec} Hz',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStats
// ---------------------------------------------------------------------------

class LiveStats extends StatelessWidget {
  final AppSettings settings;
  final DataHub hub;
  final bool showDerivative;

  const LiveStats({
    super.key,
    required this.settings,
    required this.hub,
    this.showDerivative = false,
  });

  @override
  Widget build(BuildContext context) {
    final unit = settings.displayUnit;
    final indices = settings.activeChannelIndices;

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              for (int i = 0; i < indices.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(
                  child: _ChannelStatChip(
                    label: settings.channelLabels[indices[i]],
                    color: _channelColor(indices[i]),
                    current: hub.currentForce(indices[i], unit),
                    peak: hub.peakForce(indices[i], unit),
                    unit: unit,
                    showDerivative: showDerivative,
                    currentDerivative: showDerivative
                        ? hub.currentDerivative(indices[i], unit)
                        : null,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// DisconnectedPrompt
// ---------------------------------------------------------------------------

class DisconnectedPrompt extends StatelessWidget {
  const DisconnectedPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No device connected',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () {
              final shell = context.findAncestorStateOfType<AppShellState>();
              shell?.switchToTab(2);
            },
            child: const Text('Connect a device'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ChannelLegend (with derivative toggle)
// ---------------------------------------------------------------------------

class ChannelLegend extends StatelessWidget {
  final AppSettings settings;
  final bool showDerivative;
  final VoidCallback onToggleDerivative;

  const ChannelLegend({
    super.key,
    required this.settings,
    this.showDerivative = false,
    required this.onToggleDerivative,
  });

  @override
  Widget build(BuildContext context) {
    final indices = settings.activeChannelIndices;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // Channel legend items
          for (final idx in indices)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _channelColor(idx),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    settings.channelLabels[idx],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          const Spacer(),
          // Derivative toggle
          SizedBox(
            height: 28,
            child: FilterChip(
              label: Text(
                'dF/dt',
                style: TextStyle(
                  fontSize: 11,
                  color: showDerivative ? cs.onSecondaryContainer : null,
                ),
              ),
              selected: showDerivative,
              onSelected: (_) => onToggleDerivative(),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ActionButtons
// ---------------------------------------------------------------------------

class ActionButtons extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onToggleRecord;
  final VoidCallback onTare;

  const ActionButtons({
    super.key,
    required this.isRecording,
    required this.onToggleRecord,
    required this.onTare,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          FilledButton.icon(
            onPressed: onToggleRecord,
            icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(isRecording ? 'STOP' : 'REC'),
            style: FilledButton.styleFrom(
              backgroundColor: isRecording
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
              foregroundColor: isRecording
                  ? Theme.of(context).colorScheme.onError
                  : Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          OutlinedButton.icon(
            onPressed: onTare,
            icon: const Icon(Icons.exposure_zero),
            label: const Text('TARE'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channel stat chip widget
// ---------------------------------------------------------------------------

class _ChannelStatChip extends StatelessWidget {
  const _ChannelStatChip({
    required this.label,
    required this.color,
    required this.current,
    required this.peak,
    required this.unit,
    this.showDerivative = false,
    this.currentDerivative,
  });

  final String label;
  final Color color;
  final double current;
  final double peak;
  final ForceUnit unit;
  final bool showDerivative;
  final double? currentDerivative;

  @override
  Widget build(BuildContext context) {
    final monoStyle = GoogleFonts.robotoMono(
      textStyle: Theme.of(context).textTheme.bodySmall,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
          Text(
            unit.format(current),
            style: GoogleFonts.robotoMono(
              textStyle: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Text('Peak: ${unit.format(peak)}', style: monoStyle),
          if (showDerivative && currentDerivative != null)
            Text(
              'dF/dt: ${_formatDerivative(currentDerivative!, unit)}',
              style: monoStyle,
            ),
        ],
      ),
    );
  }

  static String _formatDerivative(double value, ForceUnit unit) {
    final sign = value < 0 ? '' : '+';
    final abs = value.abs();
    if (abs >= 1000) return '$sign${value.toStringAsFixed(0)} ${unit.symbol}/s';
    if (abs >= 100) return '$sign${value.toStringAsFixed(1)} ${unit.symbol}/s';
    if (abs >= 10) return '$sign${value.toStringAsFixed(2)} ${unit.symbol}/s';
    return '$sign${value.toStringAsFixed(3)} ${unit.symbol}/s';
  }
}

// ---------------------------------------------------------------------------
// Channel colors
// ---------------------------------------------------------------------------

Color _channelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}

// ---------------------------------------------------------------------------
// Shared axis-scale helpers
// ---------------------------------------------------------------------------

typedef _ScaleConfigItem = ({int limit, int delta});

const List<_ScaleConfigItem> _xScaleConfig = [
  (limit: 1, delta: 1),
  (limit: 2, delta: 1),
  (limit: 5, delta: 1),
  (limit: 10, delta: 2),
  (limit: 30, delta: 5),
  (limit: 60, delta: 10),
  (limit: 120, delta: 20),
  (limit: 300, delta: 30),
  (limit: 600, delta: 60),
];

_ScaleConfigItem _findScale(double val, List<_ScaleConfigItem> list) {
  return list.firstWhere((e) => val < e.limit, orElse: () => list.last);
}

String _fmtTime(int sec) {
  if (sec < 60) return sec.toString();
  final s = (sec % 60 < 10) ? '0' : '';
  return '${sec ~/ 60}:$s${sec % 60}';
}

/// Format fractional seconds for sub-second X labels.
String _fmtTimeFrac(double sec) {
  if (sec >= 60) {
    final m = sec ~/ 60;
    final s = sec - m * 60;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }
  if (sec >= 1) return sec.toStringAsFixed(1);
  return '${(sec * 1000).round()}ms';
}

// Label paragraph cache
final Map<String, ui.Paragraph> _labelCache = HashMap();

ui.Paragraph _prepareLabel(String text, {Color color = Colors.black}) {
  final key = '$text|${color.toARGB32()}';
  return _labelCache.putIfAbsent(key, () {
    final style = ui.TextStyle(color: color, fontSize: 11);
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
          )
          ..pushStyle(style)
          ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: 80));
  });
}

// ---------------------------------------------------------------------------
// Compute nice Y-axis range for data that spans [dataMin, dataMax] in display units.
// Returns (yMin, yMax, tickDelta) where yMin <= 0 <= yMax (if data crosses zero)
// and tickDelta is the spacing between major ticks.
// ---------------------------------------------------------------------------

({double yMin, double yMax, double tickDelta}) _computeYRange(
  double dataMin,
  double dataMax,
) {
  // Ensure some minimum range to avoid degenerate axes
  if (dataMax - dataMin < 0.001) {
    dataMax = dataMin + 1.0;
  }

  final range = dataMax - dataMin;

  // Pick a nice tick delta: find the order of magnitude, then use 1/2/5 steps
  final rawStep = range / 5; // aim for ~5 ticks
  final mag = math.pow(10, (math.log(rawStep) / math.ln10).floor()).toDouble();
  double tickDelta;
  if (rawStep / mag < 1.5) {
    tickDelta = mag;
  } else if (rawStep / mag < 3.5) {
    tickDelta = mag * 2;
  } else if (rawStep / mag < 7.5) {
    tickDelta = mag * 5;
  } else {
    tickDelta = mag * 10;
  }

  if (tickDelta < 0.001) tickDelta = 0.001;

  // Snap yMin and yMax to tick boundaries
  final yMin = (dataMin / tickDelta).floor() * tickDelta;
  final yMax = (dataMax / tickDelta).ceil() * tickDelta;

  return (yMin: yMin, yMax: yMax, tickDelta: tickDelta);
}

// ---------------------------------------------------------------------------
// Live graph painter (force)
// ---------------------------------------------------------------------------

class _LiveGraphPainter extends CustomPainter {
  final DataHub _data;
  final AppSettings _settings;
  final GraphController _ctrl;
  final bool showXLabels;

  _LiveGraphPainter(
    this._data,
    this._settings,
    this._ctrl, {
    this.showXLabels = true,
  }) : super(repaint: _data);

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke;

    const double leftSpace = 8;
    const double rightSpace = 56;
    const double bottomSpace = 24;
    const double topSpace = 4;

    canvas.translate(leftSpace, topSpace);
    final graphSz = Size(
      size.width - leftSpace - rightSpace,
      size.height - (showXLabels ? bottomSpace : 4) - topSpace,
    );

    if (graphSz.width <= 0 || graphSz.height <= 0) return;

    canvas.drawRect(
      Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
      pen..strokeWidth = 0.5,
    );

    if (_data.rawSz == 0) return;

    final unit = _settings.displayUnit;
    final activeIndices = _settings.activeChannelIndices;
    final (viewStart, viewEnd) = _ctrl.effectiveRange(_data.rawSz);
    final viewSamples = viewEnd - viewStart;
    if (viewSamples <= 0) return;

    // Compute data min/max across active channels in visible window (raw, tare-subtracted).
    // Start with actual extremes then enforce a minimum visible range.
    double rawMax = 0;
    double rawMin = 0;
    bool hasData = false;

    if (_ctrl.isLive && viewStart == 0) {
      // Full view -- use pre-tracked global min/max (O(1))
      for (final ch in activeIndices) {
        final lineIdx = DataHub.chanToLine(ch);
        if (lineIdx < 0) continue;
        final mx = (_data.rawMax[lineIdx] - _data.tare[lineIdx]).toDouble();
        final mn = (_data.rawMin[lineIdx] - _data.tare[lineIdx]).toDouble();
        if (!hasData || mx > rawMax) rawMax = mx;
        if (!hasData || mn < rawMin) rawMin = mn;
        hasData = true;
      }
    } else {
      // Zoomed/panned -- scan visible window for actual min/max
      for (final ch in activeIndices) {
        final lineIdx = DataHub.chanToLine(ch);
        if (lineIdx < 0) continue;
        final line = _data.rawData[lineIdx];
        final tare = _data.tare[lineIdx];
        for (int i = viewStart; i < viewEnd; i++) {
          final v = line[i] - tare;
          if (!hasData || v > rawMax) rawMax = v.toDouble();
          if (!hasData || v < rawMin) rawMin = v.toDouble();
          hasData = true;
        }
      }
    }

    // Enforce a minimum visible range (noise floor) so the graph isn't degenerate
    const double noiseFloor = 10000; // raw counts
    if (rawMax - rawMin < noiseFloor) {
      final mid = (rawMax + rawMin) / 2;
      rawMax = mid + noiseFloor / 2;
      rawMin = mid - noiseFloor / 2;
    }

    final double dataMaxUnit = unit.fromKgf(
      rawMax * _data.deviceCalibration.slope,
    );
    final double dataMinUnit = unit.fromKgf(
      rawMin * _data.deviceCalibration.slope,
    );

    // Compute nice Y axis range
    final yRange = _computeYRange(dataMinUnit, dataMaxUnit);

    // Map a value in display units to Y pixel
    double unitToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // -- Grid and labels --
    final grid = Path();

    // X axis
    final double xSpanSec = viewSamples / DataHub.samplesPerSec;

    if (xSpanSec < 1.0) {
      // Sub-second: use fractional labels
      final stepMs = xSpanSec * 1000 / 5; // aim for ~5 labels
      final niceStepMs = _niceNum(stepMs);
      final startSec = viewStart / DataHub.samplesPerSec;

      final firstTickMs = ((startSec * 1000 / niceStepMs).ceil() * niceStepMs);
      for (
        double tMs = firstTickMs;
        tMs < (viewEnd / DataHub.samplesPerSec) * 1000;
        tMs += niceStepMs
      ) {
        final tSec = tMs / 1000;
        final xPos =
            (tSec - startSec) *
            DataHub.samplesPerSec *
            graphSz.width /
            viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        if (showXLabels) {
          final par = _prepareLabel(_fmtTimeFrac(tSec));
          canvas.drawParagraph(
            par,
            Offset(xPos - par.longestLine / 2, graphSz.height + 2),
          );
        }
      }
    } else {
      final xC = _findScale(xSpanSec, _xScaleConfig);
      final double startSec = viewStart / DataHub.samplesPerSec;

      // Major grid + labels
      final int firstTick = ((startSec / xC.delta).ceil() * xC.delta).toInt();
      final double endSec = viewEnd / DataHub.samplesPerSec;
      for (int sec = firstTick; sec.toDouble() < endSec; sec += xC.delta) {
        final double xPos =
            (sec - startSec) *
            DataHub.samplesPerSec *
            graphSz.width /
            viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        if (showXLabels) {
          final par = _prepareLabel(_fmtTime(sec));
          canvas.drawParagraph(
            par,
            Offset(xPos - par.longestLine / 2, graphSz.height + 2),
          );
        }
      }

      // Minor grid (half delta)
      final double minorDeltaSec = xC.delta / 2;
      final double firstMinor =
          (startSec / minorDeltaSec).ceil() * minorDeltaSec;
      for (double sec = firstMinor; sec < endSec; sec += minorDeltaSec) {
        final double xPos =
            (sec - startSec) *
            DataHub.samplesPerSec *
            graphSz.width /
            viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
      }
    }

    // Y axis grid + labels
    {
      final delta = yRange.tickDelta;
      // Start from the first tick at or above yMin
      double tick = (yRange.yMin / delta).ceil() * delta;
      while (tick <= yRange.yMax + delta * 0.01) {
        final yPos = unitToY(tick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);

          // Label
          final labelStr = _formatTickLabel(tick, unit.symbol);
          final par = _prepareLabel(labelStr);
          canvas.drawParagraph(
            par,
            Offset(graphSz.width + 4, yPos - par.height / 2),
          );
        }
        tick += delta;
      }

      // Minor grid (half delta)
      final minorDelta = delta / 2;
      double minorTick = (yRange.yMin / minorDelta).ceil() * minorDelta;
      while (minorTick <= yRange.yMax + minorDelta * 0.01) {
        final yPos = unitToY(minorTick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);
        }
        minorTick += minorDelta;
      }
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // -- Zero baseline --
    if (yRange.yMin < 0 && yRange.yMax > 0) {
      final zeroY = unitToY(0);
      final zeroPaint = Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawLine(
        Offset(0, zeroY),
        Offset(graphSz.width, zeroY),
        zeroPaint,
      );
    }

    // -- Data lines --
    final rawRange = yRange.yMax - yRange.yMin;
    final slopeToUnit =
        _data.deviceCalibration.slope *
        (unit == ForceUnit.kgf
            ? 1.0
            : unit == ForceUnit.n
            ? 9.80665
            : unit == ForceUnit.kN
            ? 9.80665 / 1000.0
            : 2.20462);

    for (final ch in activeIndices) {
      final lineIdx = DataHub.chanToLine(ch);
      if (lineIdx < 0) continue;

      final avgPath = Path();
      final envPath = Path();
      final line = _data.rawData[lineIdx];
      final tare = _data.tare[lineIdx];

      final int graphW = graphSz.width.toInt();
      bool first = true;

      for (int i = 0; i < graphW; ++i) {
        // Map pixel i to sample range
        final int sStart = viewStart + (i * viewSamples ~/ graphW);
        final int sEnd = viewStart + ((i + 1) * viewSamples ~/ graphW);
        if (sStart >= sEnd) continue;

        double total = 0;
        double minRaw = double.infinity;
        double maxRaw = double.negativeInfinity;

        for (int j = sStart; j < sEnd; j++) {
          final val = line[j];
          total += val;
          if (val < minRaw) minRaw = val.toDouble();
          if (val > maxRaw) maxRaw = val.toDouble();
        }

        final avgRaw = total / (sEnd - sStart);

        final avgUnit = (avgRaw - tare) * slopeToUnit;
        final minUnit = (minRaw - tare) * slopeToUnit;
        final maxUnit = (maxRaw - tare) * slopeToUnit;

        final avgY =
            (graphSz.height -
                    (avgUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);
        final minY =
            (graphSz.height -
                    (minUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);
        final maxY =
            (graphSz.height -
                    (maxUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);

        if (first) {
          avgPath.moveTo(i.toDouble(), avgY);
          envPath.moveTo(i.toDouble(), minY);
          envPath.lineTo(i.toDouble(), maxY);
          first = false;
        } else {
          avgPath.lineTo(i.toDouble(), avgY);
          envPath.moveTo(i.toDouble(), minY);
          envPath.lineTo(i.toDouble(), maxY);
        }
      }

      final chColor = _channelColor(ch);

      // Draw envelope first (lighter)
      pen.color = chColor.withAlpha(60);
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Draw average line on top
      pen.color = chColor;
      canvas.drawPath(avgPath, pen..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Derivative graph painter
// ---------------------------------------------------------------------------

class _DerivativeGraphPainter extends CustomPainter {
  final DataHub _data;
  final AppSettings _settings;
  final GraphController _ctrl;

  _DerivativeGraphPainter(this._data, this._settings, this._ctrl)
    : super(repaint: _data);

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke;

    const double leftSpace = 8;
    const double rightSpace = 56;
    const double bottomSpace = 24;
    const double topSpace = 2;

    canvas.translate(leftSpace, topSpace);
    final graphSz = Size(
      size.width - leftSpace - rightSpace,
      size.height - bottomSpace - topSpace,
    );

    if (graphSz.width <= 0 || graphSz.height <= 0) return;

    canvas.drawRect(
      Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
      pen..strokeWidth = 0.5,
    );

    if (_data.rawSz < 2) return;

    final unit = _settings.displayUnit;
    final activeIndices = _settings.activeChannelIndices;
    final (viewStart, viewEnd) = _ctrl.effectiveRange(_data.rawSz);
    final viewSamples = viewEnd - viewStart;
    if (viewSamples < 2) return;

    final double slopeToUnit =
        _data.deviceCalibration.slope *
        (unit == ForceUnit.kgf
            ? 1.0
            : unit == ForceUnit.n
            ? 9.80665
            : unit == ForceUnit.kN
            ? 9.80665 / 1000.0
            : 2.20462);
    final double sampleRate = DataHub.samplesPerSec.toDouble();

    // Compute derivative min/max in visible window
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    for (final ch in activeIndices) {
      final lineIdx = DataHub.chanToLine(ch);
      if (lineIdx < 0) continue;
      final line = _data.rawData[lineIdx];
      final startI = math.max(viewStart, 1);
      for (int i = startI; i < viewEnd; i++) {
        final d = (line[i] - line[i - 1]).toDouble() * slopeToUnit * sampleRate;
        if (first) {
          dMin = d;
          dMax = d;
          first = false;
        } else {
          if (d < dMin) dMin = d;
          if (d > dMax) dMax = d;
        }
      }
    }

    // Add some padding
    if (dMax - dMin < 0.001) {
      dMax = dMin + 1.0;
    }

    final yRange = _computeYRange(dMin, dMax);

    double valToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // Grid + labels
    final grid = Path();

    // X axis labels
    final double xSpanSec = viewSamples / DataHub.samplesPerSec;
    final double startSec = viewStart / DataHub.samplesPerSec;
    final double endSec = viewEnd / DataHub.samplesPerSec;

    if (xSpanSec < 1.0) {
      final stepMs = xSpanSec * 1000 / 5;
      final niceStepMs = _niceNum(stepMs);
      final firstTickMs = ((startSec * 1000 / niceStepMs).ceil() * niceStepMs);
      for (double tMs = firstTickMs; tMs < endSec * 1000; tMs += niceStepMs) {
        final tSec = tMs / 1000;
        final xPos =
            (tSec - startSec) *
            DataHub.samplesPerSec *
            graphSz.width /
            viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        final par = _prepareLabel(_fmtTimeFrac(tSec));
        canvas.drawParagraph(
          par,
          Offset(xPos - par.longestLine / 2, graphSz.height + 2),
        );
      }
    } else {
      final xC = _findScale(xSpanSec, _xScaleConfig);
      final int firstTick = ((startSec / xC.delta).ceil() * xC.delta).toInt();
      for (int sec = firstTick; sec.toDouble() < endSec; sec += xC.delta) {
        final double xPos =
            (sec - startSec) *
            DataHub.samplesPerSec *
            graphSz.width /
            viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        final par = _prepareLabel(_fmtTime(sec));
        canvas.drawParagraph(
          par,
          Offset(xPos - par.longestLine / 2, graphSz.height + 2),
        );
      }
    }

    // Y axis grid + labels
    {
      final delta = yRange.tickDelta;
      double tick = (yRange.yMin / delta).ceil() * delta;
      while (tick <= yRange.yMax + delta * 0.01) {
        final yPos = valToY(tick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);

          final labelStr = '${_formatTickValue(tick)}/s';
          final par = _prepareLabel(labelStr);
          canvas.drawParagraph(
            par,
            Offset(graphSz.width + 4, yPos - par.height / 2),
          );
        }
        tick += delta;
      }
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // Zero baseline
    if (yRange.yMin < 0 && yRange.yMax > 0) {
      final zeroY = valToY(0);
      final zeroPaint = Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawLine(
        Offset(0, zeroY),
        Offset(graphSz.width, zeroY),
        zeroPaint,
      );
    }

    // "dF/dt" label in top-left
    final dLabel = _prepareLabel(
      'dF/dt (${unit.symbol}/s)',
      color: Colors.black45,
    );
    canvas.drawParagraph(dLabel, const Offset(4, 2));

    // Data lines
    final rawYRange = yRange.yMax - yRange.yMin;
    for (final ch in activeIndices) {
      final lineIdx = DataHub.chanToLine(ch);
      if (lineIdx < 0) continue;

      final avgPath = Path();
      final envPath = Path();
      final line = _data.rawData[lineIdx];
      final int graphW = graphSz.width.toInt();
      bool pathFirst = true;

      for (int px = 0; px < graphW; ++px) {
        final int sStart = math.max(
          viewStart + (px * viewSamples ~/ graphW),
          1,
        );
        final int sEnd = math.max(
          viewStart + ((px + 1) * viewSamples ~/ graphW),
          2,
        );
        if (sStart >= sEnd || sStart >= _data.rawSz) continue;

        double total = 0;
        int count = 0;
        double minDerivRaw = double.infinity;
        double maxDerivRaw = double.negativeInfinity;

        for (int j = sStart; j < sEnd && j < _data.rawSz; j++) {
          final double d = (line[j] - line[j - 1]).toDouble();
          total += d;
          count++;
          if (d < minDerivRaw) minDerivRaw = d;
          if (d > maxDerivRaw) maxDerivRaw = d;
        }
        if (count == 0) continue;

        final avgDerivRaw = total / count;

        final avgDerivUnit = avgDerivRaw * slopeToUnit * sampleRate;
        final minDerivUnit = minDerivRaw * slopeToUnit * sampleRate;
        final maxDerivUnit = maxDerivRaw * slopeToUnit * sampleRate;

        final avgY =
            (graphSz.height -
                    (avgDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);
        final minY =
            (graphSz.height -
                    (minDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);
        final maxY =
            (graphSz.height -
                    (maxDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);

        if (pathFirst) {
          avgPath.moveTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
          pathFirst = false;
        } else {
          avgPath.lineTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
        }
      }

      final chColor = _channelColor(ch);

      // Envelope
      pen.color = chColor.withAlpha(60);
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Average
      pen.color = chColor;
      canvas.drawPath(avgPath, pen..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Format a tick value with appropriate precision.
String _formatTickLabel(double value, String unitSymbol) {
  final formatted = _formatTickValue(value);
  return '$formatted $unitSymbol';
}

String _formatTickValue(double value) {
  if (value == 0) return '0';
  final abs = value.abs();
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 1) return value.toStringAsFixed(1);
  if (abs >= 0.1) return value.toStringAsFixed(2);
  return value.toStringAsFixed(3);
}

/// Return a "nice" number close to [value] for axis step sizes.
double _niceNum(double value) {
  if (value <= 0) return 1;
  final exp = (math.log(value) / math.ln10).floor();
  final frac = value / math.pow(10, exp);
  double nice;
  if (frac < 1.5) {
    nice = 1;
  } else if (frac < 3.5) {
    nice = 2;
  } else if (frac < 7.5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * math.pow(10, exp);
}
