import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../utils/format.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import '../widgets/graph_components.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  /// Load state of the session's sample data (see [_LoadState]).
  _LoadState _loadState = const _Loading();

  final GraphController _graphCtrl = GraphController();

  /// The session row, reactively. Single source of truth for name, notes,
  /// duration, and the per-session channel-visibility set: edits (from here
  /// or anywhere else) are written to the DB and surface via this stream, so
  /// no mirrored copies (and no manual reload calls) live in this widget.
  late final Stream<Session?> _sessionStream;

  @override
  void initState() {
    super.initState();
    _sessionStream = AppDatabase.instance.watchSessionById(widget.session.id);
    unawaited(_loadData());
  }

  /// Parse the JSON-encoded per-channel visibility stored on a [Session]
  /// row. Missing or malformed entries fall back to visible.
  static List<bool> _parseVisibleChannels(String json, int channelCount) =>
      parseJsonColumn(
        json,
        channelCount,
        convert: (e) => e == true,
        fallback: (_) => true,
      );

  /// Persist a channel-visibility flip; the row stream drives the UI update.
  Future<void> _toggleChannel(
    Session session,
    List<bool> current,
    int index,
  ) async {
    final updated = [...current];
    updated[index] = !updated[index];
    await AppDatabase.instance.setSessionVisibleChannels(
      session.id,
      jsonEncode(updated),
    );
  }

  @override
  void dispose() {
    _graphCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await SessionStorage.loadSession(widget.session);
      if (!mounted) return;
      setState(() => _loadState = _Ready(data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadState = _Failed(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return StreamBuilder<Session?>(
      stream: _sessionStream,
      builder: (context, snapshot) {
        // Until the stream's first emission — and after the row is deleted on
        // the way out — fall back to the row this screen was pushed with.
        final session = snapshot.data ?? widget.session;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              session.name.isEmpty ? 'Untitled Session' : session.name,
            ),
            actions: [
              PopupMenuButton<String>(
                onSelected: (action) => _onMenuAction(action, session),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(
                    value: 'notes',
                    child: Text('Edit notes'),
                  ),
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
          body: switch (_loadState) {
            _Loading() => const Center(child: CircularProgressIndicator()),
            _Failed(:final error) => Center(child: Text('Error: $error')),
            // A session without chunks (e.g. deleted externally) has nothing to
            // show; loadSession returns null there.
            _Ready(data: null) => const Center(
              child: Text('No recorded data for this session'),
            ),
            _Ready(:final data) => _buildContent(settings, session, data!),
          },
        );
      },
    );
  }

  Widget _buildContent(
    AppSettings settings,
    Session session,
    SessionData data,
  ) {
    final unit = settings.displayUnit;
    final visibleChannels = _parseVisibleChannels(
      session.visibleChannels,
      session.channelCount,
    );

    final channelLabels = parseJsonColumn(
      session.channelLabels,
      data.channels.length,
      convert: (e) => e.toString(),
      fallback: (i) => 'Ch ${i + 1}',
    );

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Channel header (same tappable table as the live view; toggles
          // this session's per-session channel visibility).
          ChannelStatsTable(
            labels: channelLabels,
            activeChannels: visibleChannels,
            onToggleChannel: (index) =>
                unawaited(_toggleChannel(session, visibleChannels, index)),
            unit: unit,
            rows: [
              ChannelStatsRow(
                label: 'Peak',
                emphasized: true,
                values: [
                  for (int ch = 0; ch < data.channels.length; ch++)
                    unit
                        .converterFor(data.calibrationFor(ch), data.tares[ch])
                        ?.call(data.maxs[ch]),
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
                data: data,
                ctrl: _graphCtrl,
                settings: settings,
                activeChannels: [
                  for (int i = 0; i < visibleChannels.length; i++)
                    if (visibleChannels[i]) i,
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
                  value: formatDuration(
                    Duration(milliseconds: session.durationMs),
                  ),
                ),
                _StatRow(
                  label: 'Sample Rate',
                  value: '${session.sampleRate} Hz',
                ),
                _StatRow(label: 'Samples', value: '${data.sampleCount}'),
              ],
            ),
          ),

          // Notes
          if (session.notes.isNotEmpty) ...[
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Notes', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(session.notes),
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
                    onPressed: () => _exportCsv(session, data),
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

  Future<void> _onMenuAction(String action, Session session) async {
    switch (action) {
      case 'rename':
        await _showRenameDialog(session);
      case 'notes':
        await _showNotesDialog(session);
      case 'export_csv':
        final state = _loadState;
        if (state is _Ready && state.data != null) {
          await _exportCsv(session, state.data!);
        }
      case 'delete':
        await _deleteAndPop(session);
    }
  }

  Future<void> _showRenameDialog(Session session) => renameSessionFlow(
    context,
    sessionId: session.id,
    currentName: session.name,
  );

  Future<void> _showNotesDialog(Session session) async {
    final newNotes = await showTextPrompt(
      context,
      title: 'Edit notes',
      label: 'Notes',
      initial: session.notes,
      maxLines: 5,
    );
    if (newNotes != null) {
      await AppDatabase.instance.setSessionNotes(session.id, newNotes);
    }
  }

  Future<void> _deleteAndPop(Session session) async {
    if (await deleteSessionFlow(context, session)) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _exportCsv(Session session, SessionData data) async {
    final labels = parseJsonColumn(
      session.channelLabels,
      data.channels.length,
      convert: (e) => e.toString(),
      fallback: (i) => 'Ch ${i + 1}',
    );

    // TODO(perf): build this incrementally (chunked writes) — a long session
    // produces a very large single string (see SessionStorage.loadSession's
    // own note about whole-session materialization).
    final buf = StringBuffer();
    buf.write('time_s');
    for (int ch = 0; ch < data.channels.length; ch++) {
      final label = _csvCell(labels[ch]);
      buf.write(',${label}_raw,${label}_kgf');
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
          // kgf via the calibration recorded with the session; blank when
          // the channel had no load cell assigned.
          final kgf = ForceUnit.kgf
              .converterFor(data.calibrationFor(ch), data.tares[ch])
              ?.call(raw.toDouble());
          buf.write(kgf == null ? ',$raw,' : ',$raw,${kgf.toStringAsFixed(6)}');
        }
      }
      buf.writeln();
    }

    // Save via a native "Save As" dialog. On web there is no save-location
    // picker, so hand the bytes to the browser, which downloads the file.
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    final csvName = _csvFileName(session.name);
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
}

// -- Load state --

/// Escape a CSV header cell that contains separators, quotes or newlines.
String _csvCell(String s) =>
    s.contains(RegExp(r'[,"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;

/// The CSV filename for a session: the session name with characters that are
/// illegal in Windows/macOS/Android filenames replaced (auto session names
/// contain `/` and `:` — e.g. `7/20 14:05:32`), and trailing dots/spaces
/// (illegal on Windows) trimmed.
String _csvFileName(String sessionName) {
  final base = sessionName.isEmpty ? 'session' : sessionName;
  final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
  final trimmed = safe.replaceAll(RegExp(r'[. ]+$'), '');
  return '${trimmed.isEmpty ? 'session' : trimmed}.csv';
}

/// Load state for the session's sample data: still loading, failed, or ready
/// (data null means the session has no chunks).
sealed class _LoadState {
  const _LoadState();
}

final class _Loading extends _LoadState {
  const _Loading();
}

final class _Failed extends _LoadState {
  const _Failed(this.error);

  final Object error;
}

final class _Ready extends _LoadState {
  const _Ready(this.data);

  final SessionData? data;
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
