import 'dart:ui' as ui;
import 'dart:collection';

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

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  void _onTare() {
    final bt = context.read<BluetoothHandling>();
    bt.dataHub.requestTare();
  }

  void _onTogglePause() {
    final bt = context.read<BluetoothHandling>();
    bt.dataHub.togglePause();
    setState(() {}); // rebuild to update button label
  }

  void _onClear() {
    final bt = context.read<BluetoothHandling>();
    bt.dataHub.clear();
    setState(() {}); // rebuild to update button states
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
          if (isConnected) LiveStats(settings: settings, hub: bt.dataHub),
          Expanded(
            child: isConnected
                ? CustomPaint(
                    foregroundPainter: _LiveGraphPainter(bt.dataHub, settings),
                    size: Size.infinite,
                  )
                : const DisconnectedPrompt(),
          ),
          if (isConnected) ChannelLegend(settings: settings),
          if (isConnected)
            ActionButtons(
              isRecording: bt.sessionInProgress,
              isPaused: bt.dataHub.paused,
              onToggleRecord: _onToggleRecord,
              onTogglePause: _onTogglePause,
              onTare: _onTare,
              onClear: bt.sessionInProgress ? null : _onClear,
            ),
        ],
      ),
    );
  }
}

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
                    : 'Not connected — tap to connect',
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

class LiveStats extends StatelessWidget {
  final AppSettings settings;
  final DataHub hub;

  const LiveStats({super.key, required this.settings, required this.hub});

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

class ChannelLegend extends StatelessWidget {
  final AppSettings settings;

  const ChannelLegend({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final indices = settings.activeChannelIndices;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
        ],
      ),
    );
  }
}

class ActionButtons extends StatelessWidget {
  final bool isRecording;
  final bool isPaused;
  final VoidCallback onToggleRecord;
  final VoidCallback onTogglePause;
  final VoidCallback onTare;
  final VoidCallback? onClear;

  const ActionButtons({
    super.key,
    required this.isRecording,
    required this.isPaused,
    required this.onToggleRecord,
    required this.onTogglePause,
    required this.onTare,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
              backgroundColor: isRecording ? cs.error : cs.primary,
              foregroundColor: isRecording ? cs.onError : cs.onPrimary,
            ),
          ),
          OutlinedButton.icon(
            onPressed: onTogglePause,
            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
            label: Text(isPaused ? 'RESUME' : 'PAUSE'),
            style: isPaused
                ? OutlinedButton.styleFrom(
                    foregroundColor: cs.tertiary,
                    side: BorderSide(color: cs.tertiary),
                  )
                : null,
          ),
          OutlinedButton.icon(
            onPressed: onTare,
            icon: const Icon(Icons.exposure_zero),
            label: const Text('TARE'),
          ),
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('CLEAR'),
          ),
        ],
      ),
    );
  }
}

// -- Channel stat chip widget --

class _ChannelStatChip extends StatelessWidget {
  const _ChannelStatChip({
    required this.label,
    required this.color,
    required this.current,
    required this.peak,
    required this.unit,
  });

  final String label;
  final Color color;
  final double current;
  final double peak;
  final ForceUnit unit;

  @override
  Widget build(BuildContext context) {
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
          Text(
            'Peak: ${unit.format(peak)}',
            style: GoogleFonts.robotoMono(
              textStyle: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// -- Channel colors --

Color _channelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}

// -- Live graph painter --

typedef _ScaleConfigItem = ({int limit, int delta});

class _LiveGraphPainter extends CustomPainter {
  final DataHub _data;
  final AppSettings _settings;

  _LiveGraphPainter(this._data, this._settings) : super(repaint: _data);

  // Seconds
  static const List<_ScaleConfigItem> _xScaleConfig = [
    (limit: 5, delta: 1),
    (limit: 10, delta: 2),
    (limit: 30, delta: 5),
    (limit: 60, delta: 10),
    (limit: 120, delta: 20),
    (limit: 300, delta: 30),
    (limit: 600, delta: 60),
  ];
  static final Map<int, ui.Paragraph> _xLabels = HashMap();

  // Y-axis labels are unit-dependent, so we cache per-unit.
  static final Map<(ForceUnit, int), ui.Paragraph> _yLabels = HashMap();

  // Y scale configs per unit (approximate ranges).
  static const List<_ScaleConfigItem> _yScaleConfigKgf = [
    (limit: 5, delta: 1),
    (limit: 10, delta: 2),
    (limit: 20, delta: 5),
    (limit: 50, delta: 10),
    (limit: 100, delta: 20),
    (limit: 200, delta: 50),
    (limit: 500, delta: 100),
    (limit: 1000, delta: 200),
  ];

  static ui.Paragraph _prepareLabel(String text) {
    final style = ui.TextStyle(color: Colors.black, fontSize: 12);
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
          )
          ..pushStyle(style)
          ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: 72));
  }

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
      size.height - bottomSpace - topSpace,
    );
    canvas.drawRect(
      Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
      pen..strokeWidth = 0.5,
    );

    if (_data.rawSz == 0) return;

    final unit = _settings.displayUnit;
    final activeIndices = _settings.activeChannelIndices;

    // Compute data max across active channels (in raw units, tare-subtracted)
    double dataMax = 10000; // above noise floor
    for (final ch in activeIndices) {
      final lineIdx = DataHub.chanToLine(ch);
      if (lineIdx < 0) continue;
      final double x = (_data.rawMax[lineIdx] - _data.tare[lineIdx]).toDouble();
      if (x > dataMax) dataMax = x;
    }

    final double dataMaxKgf = dataMax * _data.deviceCalibration.slope;
    final double dataMaxUnit = unit.fromKgf(dataMaxKgf);

    // X axis
    final double xSpanSec = _data.rawSz / DataHub.samplesPerSec;
    final xC = _findScale(xSpanSec, _xScaleConfig);

    double secondsToX(int sec) =>
        sec * DataHub.samplesPerSec * graphSz.width / _data.rawSz;

    final grid = Path();
    final double xMinorDelta = secondsToX(xC.delta) / 2;
    for (double x = xMinorDelta; x < graphSz.width; x += xMinorDelta) {
      grid.moveTo(x, 0);
      grid.lineTo(x, graphSz.height);
    }
    for (int i = xC.delta; i.toDouble() < xSpanSec; i += xC.delta) {
      final double xPos = secondsToX(i);
      final par = _xLabels.putIfAbsent(i, () => _prepareLabel(_fmtTime(i)));
      canvas.drawParagraph(
        par,
        Offset(xPos - par.longestLine / 2, graphSz.height),
      );
    }

    // Y axis (in display units)
    // We scale yScaleConfig by the unit conversion factor
    final double unitScale = unit.fromKgf(1.0); // units per kgf
    final yC = _findScale(
      dataMaxUnit,
      _yScaleConfigKgf
          .map(
            (e) => (
              limit: (e.limit * unitScale).ceil(),
              delta: (e.delta * unitScale).ceil().clamp(1, 999999),
            ),
          )
          .toList(),
    );

    double unitToY(double val) => val * graphSz.height / dataMaxUnit;

    final double yMinorDelta = unitToY(yC.delta.toDouble()) / 2;
    for (double y = yMinorDelta; y < graphSz.height; y += yMinorDelta) {
      grid.moveTo(0, graphSz.height - y);
      grid.lineTo(graphSz.width, graphSz.height - y);
    }
    for (int i = yC.delta; i < dataMaxUnit.ceil(); i += yC.delta) {
      final double yPos = graphSz.height - unitToY(i.toDouble());
      final par = _yLabels.putIfAbsent((
        unit,
        i,
      ), () => _prepareLabel('$i ${unit.symbol}'));
      canvas.drawParagraph(
        par,
        Offset(graphSz.width + 4, yPos - par.height / 2),
      );
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // Draw data lines for each active channel
    for (final ch in activeIndices) {
      final lineIdx = DataHub.chanToLine(ch);
      if (lineIdx < 0) continue;

      final path = Path();

      double rawToY(double val) {
        final double y =
            graphSz.height -
            (val - _data.tare[lineIdx]) * graphSz.height / dataMax;
        return y.clamp(0, graphSz.height);
      }

      path.moveTo(0, rawToY(_data.tare[lineIdx]));
      final int graphW = graphSz.width.toInt();
      for (int i = 0, j = 0; i < graphW; ++i) {
        int total = 0;
        final int start = j;
        for (; (j * graphW < i * _data.rawSz) && (j < _data.rawSz); ++j) {
          total += _data.rawData[lineIdx][j];
        }
        if (start < j) {
          path.lineTo(i.toDouble(), rawToY(total / (j - start)));
        }
      }

      pen.color = _channelColor(ch);
      canvas.drawPath(path, pen..strokeWidth = 1.5);
    }
  }

  static _ScaleConfigItem _findScale(double val, List<_ScaleConfigItem> list) {
    return list.firstWhere((e) => val < e.limit, orElse: () => list.last);
  }

  static String _fmtTime(int sec) {
    if (sec < 60) return sec.toString();
    final s = (sec % 60 < 10) ? '0' : '';
    return '${sec ~/ 60}:$s${sec % 60}';
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
