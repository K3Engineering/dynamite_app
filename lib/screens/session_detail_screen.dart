import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import 'live_tab.dart' show GraphController;
import '../widgets/graph_components.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionMinimapDataSource implements MinimapDataSource {
  final SessionData _data;
  final List<double> _mins;
  final List<double> _maxs;

  _SessionMinimapDataSource(this._data)
    : _mins = List.filled(_data.channels.length, 0.0),
      _maxs = List.filled(_data.channels.length, 0.0) {
    for (int ch = 0; ch < _data.channels.length; ch++) {
      if (_data.sampleCount == 0) continue;
      double min = double.infinity;
      double max = double.negativeInfinity;
      for (final val in _data.channels[ch]) {
        if (val < min) min = val.toDouble();
        if (val > max) max = val.toDouble();
      }
      _mins[ch] = min;
      _maxs[ch] = max;
    }
  }

  @override
  int get sampleCount => _data.sampleCount;

  @override
  List<int> getChannelData(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= _data.channels.length) return [];
    return _data.channels[channelIndex]
        .toList(); // Data is Uint32List usually, cast to int
  }

  @override
  double getChannelMin(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= _mins.length) return 0.0;
    return _mins[channelIndex];
  }

  @override
  double getChannelMax(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= _maxs.length) return 0.0;
    return _maxs[channelIndex];
  }

  @override
  double getChannelTare(int channelIndex) => 0.0; // Sessions are already tared
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  SessionData? _data;
  bool _loading = true;
  String? _error;

  late Session _session;
  final GraphController _graphCtrl = GraphController();

  // Gesture tracking
  double? _panStartX;
  int? _panStartSample;
  int? _panEndSample;
  double? _scaleStartSpan;
  double? _pinchFocalX;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    unawaited(_loadData());
  }

  @override
  void dispose() {
    _graphCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await SessionStorage.loadSession(_session);
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<String> _parseChannelLabels(String jsonLabels) {
    try {
      final List<dynamic> decoded = jsonDecode(jsonLabels);
      return decoded.map((e) => e.toString()).toList();
    } catch (e) {
      // Fallback for older sessions that saved labels via .toString() -> "[A, B]"
      final trimmed = jsonLabels.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        return trimmed
            .substring(1, trimmed.length - 1)
            .split(',')
            .map((e) => e.trim())
            .toList();
      }
      return [];
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_data == null) return;
    final total = _data!.sampleCount;
    if (total == 0) return;

    final (s, e) = _graphCtrl.effectiveRange(total);
    _panStartSample = s;
    _panEndSample = e;
    _panStartX = details.localFocalPoint.dx;
    _scaleStartSpan = (e - s).toDouble();
    _pinchFocalX = details.localFocalPoint.dx;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    if (_data == null) return;
    final total = _data!.sampleCount;
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
      }

      _graphCtrl.setWindow(newStart, newEnd);
    }
  }

  void _onPointerSignal(PointerSignalEvent event, double graphWidth) {
    if (event is PointerScrollEvent) {
      if (_data == null) return;
      final total = _data!.sampleCount;
      if (total == 0 || graphWidth <= 0) return;

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

    return Scaffold(
      appBar: AppBar(
        title: Text(_session.name.isEmpty ? 'Untitled Session' : _session.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: _onMenuAction,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'notes', child: Text('Edit notes')),
              const PopupMenuItem(
                value: 'export_csv',
                child: Text('Export CSV'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : _buildContent(settings),
    );
  }

  Widget _buildContent(AppSettings settings) {
    final data = _data!;
    final unit = settings.displayUnit;
    final slope = data.calibrationSlope;

    final activeChannels = settings.activeChannelIndices
        .where((i) => i < data.channels.length)
        .toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Graph
          SizedBox(
            height: 332,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final graphWidth = constraints.maxWidth - 8 - 56;
                  return Stack(
                    children: [
                      Column(
                        children: [
                          Expanded(
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerSignal: (e) =>
                                  _onPointerSignal(e, graphWidth),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: _onScaleStart,
                                onScaleUpdate: (d) =>
                                    _onScaleUpdate(d, graphWidth),
                                child: ListenableBuilder(
                                  listenable: _graphCtrl,
                                  builder: (context, _) => CustomPaint(
                                    painter: _SessionGraphPainter(
                                      data: data,
                                      unit: unit,
                                      activeChannels: activeChannels,
                                      ctrl: _graphCtrl,
                                    ),
                                    size: Size.infinite,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Minimap(
                            dataSource: _SessionMinimapDataSource(data),
                            activeChannels: activeChannels,
                            graphCtrl: _graphCtrl,
                            channelColors: activeChannels
                                .map((i) => _channelColor(i))
                                .toList(),
                          ),
                        ],
                      ),
                      Positioned(
                        right: 8,
                        bottom: 40,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton.small(
                              heroTag: 'sessionZoomIn',
                              onPressed: () {
                                if (data.sampleCount > 0) {
                                  _graphCtrl.zoom(1.2, 0.5, data.sampleCount);
                                }
                              },
                              child: const Icon(Icons.zoom_in),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'sessionZoomOut',
                              onPressed: () {
                                if (data.sampleCount > 0) {
                                  _graphCtrl.zoom(
                                    1 / 1.2,
                                    0.5,
                                    data.sampleCount,
                                  );
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
              ),
            ),
          ),

          // Channel legend
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < data.channels.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _channelColor(i),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Ch ${i + 1}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const Divider(height: 24),

          // Stats
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Statistics',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: 'Duration',
                  value: _formatDuration(
                    Duration(milliseconds: _session.durationMs),
                  ),
                ),
                _StatRow(
                  label: 'Sample Rate',
                  value: '${_session.sampleRate} Hz',
                ),
                _StatRow(label: 'Samples', value: '${data.sampleCount}'),
                for (int ch = 0; ch < data.channels.length; ch++) ...[
                  const Divider(height: 16),
                  Text(
                    _parseChannelLabels(_session.channelLabels).length > ch
                        ? _parseChannelLabels(_session.channelLabels)[ch]
                        : 'Channel ${ch + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: _channelColor(ch),
                    ),
                  ),
                  _StatRow(
                    label: 'Peak',
                    value: unit.format(
                      unit.fromKgf(data.peakRaw(ch).toDouble() * slope),
                    ),
                  ),
                  _StatRow(
                    label: 'Average',
                    value: unit.format(
                      unit.fromKgf(data.averageRaw(ch) * slope),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Notes
          if (_session.notes.isNotEmpty) ...[
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Notes', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_session.notes),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Export buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _exportCsv(data),
                    icon: const Icon(Icons.download),
                    label: const Text('Export CSV'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _onMenuAction(String action) async {
    switch (action) {
      case 'rename':
        await _showRenameDialog();
      case 'notes':
        await _showNotesDialog();
      case 'export_csv':
        if (_data != null) await _exportCsv(_data!);
      case 'delete':
        await _deleteAndPop();
    }
  }

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: _session.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename session'),
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
    controller.dispose();

    if (newName != null && newName.isNotEmpty) {
      await AppDatabase.instance.updateSession(
        _session.id,
        SessionsCompanion(name: Value(newName)),
      );
      // Reload session from DB
      final updated = await AppDatabase.instance.sessionById(_session.id);
      if (updated != null && mounted) {
        setState(() => _session = updated);
      }
    }
  }

  Future<void> _showNotesDialog() async {
    final controller = TextEditingController(text: _session.notes);
    final newNotes = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit notes'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Notes',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
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
    controller.dispose();

    if (newNotes != null) {
      await AppDatabase.instance.updateSession(
        _session.id,
        SessionsCompanion(notes: Value(newNotes)),
      );
      final updated = await AppDatabase.instance.sessionById(_session.id);
      if (updated != null && mounted) {
        setState(() => _session = updated);
      }
    }
  }

  Future<void> _deleteAndPop() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AppDatabase.instance.deleteSession(_session.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _exportCsv(SessionData data) async {
    // Build CSV string
    final buf = StringBuffer();
    buf.write('time_s');
    for (int ch = 0; ch < data.channels.length; ch++) {
      buf.write(',ch${ch + 1}_raw,ch${ch + 1}_kgf');
    }
    buf.writeln();

    for (int s = 0; s < data.sampleCount; s++) {
      buf.write((s / data.sampleRate).toStringAsFixed(4));
      for (int ch = 0; ch < data.channels.length; ch++) {
        final raw = data.channels[ch][s];
        final kgf = raw * data.calibrationSlope;
        buf.write(',$raw,${kgf.toStringAsFixed(6)}');
      }
      buf.writeln();
    }

    // Save to temp file
    final dir = await getTemporaryDirectory();
    final csvName = '${_session.name.isEmpty ? 'session' : _session.name}.csv';
    final csvPath = '${dir.path}/$csvName';
    await File(csvPath).writeAsString(buf.toString());

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported to $csvPath')));
    }
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes >= 1) {
      final sec = d.inSeconds % 60;
      return '${d.inMinutes}m ${sec}s';
    }
    return '${d.inSeconds}s';
  }
}

// -- Stat row widget --

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// -- Channel colors (shared) --

Color _channelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}

// -- Session graph painter (static data, similar to live painter) --

class _SessionGraphPainter extends CustomPainter {
  final SessionData data;
  final ForceUnit unit;
  final List<int> activeChannels;
  final GraphController ctrl;

  _SessionGraphPainter({
    required this.data,
    required this.unit,
    required this.activeChannels,
    required this.ctrl,
  });

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

    if (data.sampleCount == 0) return;

    final (viewStart, viewEnd) = ctrl.effectiveRange(data.sampleCount);
    final viewSamples = viewEnd - viewStart;
    if (viewSamples <= 0) return;

    // Compute data max across active channels in visible window
    double dataMax = 10000;
    for (final ch in activeChannels) {
      final chData = data.channels[ch];
      for (int i = viewStart; i < viewEnd; i++) {
        final peak = chData[i].toDouble();
        if (peak > dataMax) dataMax = peak;
      }
    }

    final double dataMaxKgf = dataMax * data.calibrationSlope;
    final double dataMaxUnit = unit.fromKgf(dataMaxKgf);

    // X axis
    final double xSpanSec = viewSamples / data.sampleRate;
    final double startSec = viewStart / data.sampleRate;
    final grid = Path();

    // X grid lines (simple: 5 divisions)
    const int xDivisions = 5;
    for (int i = 1; i < xDivisions; i++) {
      final x = graphSz.width * i / xDivisions;
      grid.moveTo(x, 0);
      grid.lineTo(x, graphSz.height);

      final label = _prepareLabel(
        '${(startSec + xSpanSec * i / xDivisions).toStringAsFixed(1)}s',
      );
      canvas.drawParagraph(
        label,
        Offset(x - label.longestLine / 2, graphSz.height),
      );
    }

    // Y grid lines (simple: 5 divisions)
    const int yDivisions = 5;
    for (int i = 1; i < yDivisions; i++) {
      final y = graphSz.height * i / yDivisions;
      grid.moveTo(0, y);
      grid.lineTo(graphSz.width, y);

      final val = dataMaxUnit * (yDivisions - i) / yDivisions;
      final label = _prepareLabel(unit.format(val));
      canvas.drawParagraph(label, Offset(graphSz.width + 4, y - 8));
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // Draw data lines
    for (final ch in activeChannels) {
      final avgPath = Path();
      final envPath = Path();
      final chData = data.channels[ch];

      bool first = true;
      final int graphW = graphSz.width.toInt();
      for (int i = 0; i < graphW; ++i) {
        // Map pixel i to sample range
        final int sStart = viewStart + (i * viewSamples ~/ graphW);
        final int sEnd = viewStart + ((i + 1) * viewSamples ~/ graphW);
        if (sStart >= sEnd) continue;

        int total = 0;
        int minRaw = 2147483647; // Max Int32
        int maxRaw = -2147483648; // Min Int32

        for (int j = sStart; j < sEnd; j++) {
          final val = chData[j];
          total += val;
          if (val < minRaw) minRaw = val;
          if (val > maxRaw) maxRaw = val;
        }

        final double avg = total / (sEnd - sStart);

        final double avgY = graphSz.height - avg * graphSz.height / dataMax;
        final double minY = graphSz.height - minRaw * graphSz.height / dataMax;
        final double maxY = graphSz.height - maxRaw * graphSz.height / dataMax;

        final clampAvgY = avgY.clamp(0.0, graphSz.height);
        final clampMinY = minY.clamp(0.0, graphSz.height);
        final clampMaxY = maxY.clamp(0.0, graphSz.height);

        if (first) {
          avgPath.moveTo(i.toDouble(), clampAvgY);
          envPath.moveTo(i.toDouble(), clampMinY);
          envPath.lineTo(i.toDouble(), clampMaxY);
          first = false;
        } else {
          avgPath.lineTo(i.toDouble(), clampAvgY);
          envPath.moveTo(i.toDouble(), clampMinY);
          envPath.lineTo(i.toDouble(), clampMaxY);
        }
      }

      final chColor = _channelColor(ch);

      // Envelope
      pen.color = chColor.withAlpha(60);
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Average line
      pen.color = chColor;
      canvas.drawPath(avgPath, pen..strokeWidth = 1.5);
    }
  }

  static ui.Paragraph _prepareLabel(String text) {
    final style = ui.TextStyle(color: Colors.black, fontSize: 10);
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
          )
          ..pushStyle(style)
          ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: 72));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
