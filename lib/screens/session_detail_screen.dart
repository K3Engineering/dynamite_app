import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';

import '../models/app_settings.dart';
import '../models/bucket_series.dart';
import '../models/gap_list.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/graph_components.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

/// Adapts static [SessionData] to the [GraphDataSource] interface. Session data
/// never changes, so [repaint] is a never-firing listenable.
class _SessionDataSource implements GraphDataSource {
  final SessionData _data;
  const _SessionDataSource(this._data);

  @override
  int get totalSamples => _data.sampleCount;

  @override
  int get bufferCapacity => _data.sampleCount;

  @override
  int get oldestSample => 0;

  @override
  int get sampleRate => _data.sampleRate;

  @override
  double get calibrationSlope => _data.calibrationSlope;

  @override
  Listenable get repaint => kNeverRepaints;

  @override
  ChannelSeries channel(int channelIndex) => (
    data: _data.channels[channelIndex],
    min: _data.mins[channelIndex],
    max: _data.maxs[channelIndex],
    tare: _data.tares[channelIndex],
    buckets: _data.valueBuckets[channelIndex].series,
  );

  @override
  BucketSeries? diffBuckets(int channelIndex) =>
      _data.diffBuckets[channelIndex].series;

  @override
  GapList get gaps => _data.gaps;
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  SessionData? _data;
  bool _loading = true;
  String? _error;

  late Session _session;
  final GraphController _graphCtrl = GraphController();

  /// Per-session channel visibility (persisted on the session row).
  late List<bool> _visibleChannels;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _visibleChannels = _parseVisibleChannels(
      _session.visibleChannels,
      _session.channelCount,
    );
    unawaited(_loadData());
  }

  /// Parse the JSON-encoded per-channel visibility stored on a [Session]
  /// row. Missing or malformed entries fall back to visible.
  static List<bool> _parseVisibleChannels(String json, int channelCount) {
    final result = List<bool>.filled(channelCount, true);
    try {
      final List<dynamic> decoded = jsonDecode(json);
      for (int i = 0; i < channelCount && i < decoded.length; i++) {
        result[i] = decoded[i] == true;
      }
    } catch (e) {
      debugPrint('Failed to parse session visible channels "$json": $e');
    }
    return result;
  }

  void _onToggleChannel(int index) {
    setState(() => _visibleChannels[index] = !_visibleChannels[index]);
    unawaited(
      AppDatabase.instance.setSessionVisibleChannels(
        _session.id,
        jsonEncode(_visibleChannels),
      ),
    );
  }

  @override
  void dispose() {
    _graphCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await SessionStorage.loadSession(_session);
      if (!mounted) return;
      setState(() {
        _data = data;
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
    final unit = settings.displayUnit;

    final storedLabels = _parseChannelLabels(_session.channelLabels);
    final channelLabels = [
      for (int ch = 0; ch < data.channels.length; ch++)
        storedLabels.length > ch ? storedLabels[ch] : 'Ch ${ch + 1}',
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Channel header (same tappable table as the live view; toggles
          // this session's per-session channel visibility).
          ChannelStatsTable(
            labels: channelLabels,
            activeChannels: _visibleChannels,
            onToggleChannel: _onToggleChannel,
            unit: unit,
            rows: [
              ChannelStatsRow(
                label: 'Peak',
                emphasized: true,
                values: [
                  for (int ch = 0; ch < data.channels.length; ch++)
                    unit.fromRaw(
                      data.maxs[ch] - data.tares[ch],
                      data.calibrationSlope,
                    ),
                ],
              ),
            ],
          ),

          // Graph
          SizedBox(
            height: 332,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: GraphWorkspace(
                data: _SessionDataSource(data),
                ctrl: _graphCtrl,
                settings: settings,
                activeChannels: [
                  for (int i = 0; i < _visibleChannels.length; i++)
                    if (_visibleChannels[i]) i,
                ],
                showDerivative: false,
                isLiveGraph: false,
              ),
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
                    storedLabels.length > ch
                        ? storedLabels[ch]
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
                        data.maxs[ch] - data.tares[ch],
                        data.calibrationSlope,
                      ),
                    ),
                  ),
                  _StatRow(
                    label: 'Average',
                    value: settings.displayUnit.format(
                      settings.displayUnit.fromRaw(
                        data.averageRaw(ch) - data.tares[ch],
                        data.calibrationSlope,
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
      await AppDatabase.instance.renameSession(_session.id, newName);
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
      await AppDatabase.instance.setSessionNotes(_session.id, newNotes);
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
      if (data.gaps.contains(s)) {
        // Dropped sample: the buffer holds a fabricated (held) value, so emit
        // blank cells rather than fake data.
        for (int ch = 0; ch < data.channels.length; ch++) {
          buf.write(',,');
        }
      } else {
        for (int ch = 0; ch < data.channels.length; ch++) {
          final raw = data.channels[ch][s];
          final kgf = (raw - data.tares[ch]) * data.calibrationSlope;
          buf.write(',$raw,${kgf.toStringAsFixed(6)}');
        }
      }
      buf.writeln();
    }

    // Save via a native "Save As" dialog. On web there is no save-location
    // picker, so hand the bytes to the browser, which downloads the file.
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    final csvName = '${_session.name.isEmpty ? 'session' : _session.name}.csv';
    final xFile = XFile.fromData(bytes, mimeType: 'text/csv', name: csvName);

    String savedTo;
    if (kIsWeb) {
      // Triggers a browser download to the user's Downloads folder.
      await xFile.saveTo(csvName);
      savedTo = csvName;
    } else {
      const typeGroup = XTypeGroup(
        label: 'CSV',
        extensions: ['csv'],
        mimeTypes: ['text/csv'],
      );
      final location = await getSaveLocation(
        suggestedName: csvName,
        acceptedTypeGroups: const [typeGroup],
      );
      if (location == null) {
        // User cancelled the dialog.
        return;
      }
      await xFile.saveTo(location.path);
      savedTo = location.path;
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported to $savedTo')));
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
