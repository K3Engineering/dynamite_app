import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../widgets/graph_components.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionMinimapDataSource extends ChangeNotifier
    implements GraphDataSource {
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
  int get sampleRate => _data.sampleRate;

  @override
  double get calibrationSlope => _data.calibrationSlope;

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
  _SessionMinimapDataSource? _dataSource;
  bool _loading = true;
  String? _error;

  late Session _session;
  final GraphController _graphCtrl = GraphController();

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    unawaited(_loadData());
  }

  @override
  void dispose() {
    _dataSource?.dispose();
    _graphCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await SessionStorage.loadSession(_session);
      if (!mounted) return;
      setState(() {
        _data = data;
        if (data != null) {
          _dataSource = _SessionMinimapDataSource(data);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
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

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Graph
          if (_dataSource != null)
            SizedBox(
              height: 332,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: GraphWorkspace(
                  data: _dataSource!,
                  ctrl: _graphCtrl,
                  settings: settings,
                  showDerivative: false,
                  isLiveGraph: false,
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
                            color: getChannelColor(i),
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
                      color: getChannelColor(ch),
                    ),
                  ),
                  _StatRow(
                    label: 'Peak',
                    value: settings.displayUnit.format(
                      settings.displayUnit.fromRaw(
                        data.peakRaw(ch).toDouble(), data.calibrationSlope,
                      ),
                    ),
                  ),
                  _StatRow(
                    label: 'Average',
                    value: settings.displayUnit.format(
                      settings.displayUnit.fromRaw(
                        data.averageRaw(ch), data.calibrationSlope,
                      ),
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
