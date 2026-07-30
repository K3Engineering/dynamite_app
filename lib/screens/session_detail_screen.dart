import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/display_unit.dart';
import '../services/csv_export.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../utils/format.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_placeholder.dart';
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
              session.name.isEmpty ? untitledSessionName : session.name,
            ),
            actions: [
              PopupMenuButton<String>(
                onSelected: (action) => _onMenuAction(action, session),
                itemBuilder: (menuContext) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(
                    value: 'notes',
                    child: Text('Edit notes'),
                  ),
                  const PopupMenuItem(
                    value: 'download_csv',
                    child: Text('Download CSV'),
                  ),
                  PopupMenuItem(
                    value: 'share_csv',
                    enabled: csvShareSupportedHere,
                    child: Text(
                      'Share CSV'
                      '${csvShareSupportedHere ? '' : ' (not supported here)'}',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    // Destructive action: the theme's error role, as in the
                    // confirm dialog's Delete button — not a raw red.
                    child: Text(
                      'Delete',
                      style: TextStyle(
                        color: Theme.of(menuContext).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: switch (_loadState) {
            _Loading() => const Center(child: CircularProgressIndicator()),
            // The same single-voice empty-state treatment as the Sessions
            // tab: a failure gets the error color, a genuinely empty session
            // stays neutral.
            _Failed(:final error) => EmptyPlaceholder(
              icon: Icons.error_outline,
              title: 'Error loading session',
              hint: '$error',
              color: Theme.of(context).colorScheme.error,
            ),
            // A session without chunks (e.g. deleted externally) has nothing
            // to show; loadSession returns null there.
            _Ready(data: null) => const EmptyPlaceholder(
              icon: Icons.insert_chart_outlined,
              title: 'No recorded data for this session',
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

          // Export buttons: download (save-as dialog / browser download) on
          // every platform, share sheet wherever the OS has one.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _downloadCsv(session, data),
                    icon: const Icon(Icons.download),
                    label: const Text('Download CSV'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: csvShareSupportedHere
                        ? () => _shareCsv(session, data)
                        : null,
                    icon: const Icon(Icons.share),
                    label: const Text('Share CSV'),
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
      case 'download_csv':
        final state = _loadState;
        if (state is _Ready && state.data != null) {
          await _downloadCsv(session, state.data!);
        }
      case 'share_csv':
        final state = _loadState;
        if (state is _Ready && state.data != null) {
          await _shareCsv(session, state.data!);
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

  Future<void> _downloadCsv(Session session, SessionData data) =>
      _runCsvAction(() async {
        final unit = await _pickExportUnit(_recordedUnit(session));
        if (unit == null) return null;
        return downloadSessionCsv(session: session, data: data, unit: unit);
      });

  Future<void> _shareCsv(Session session, SessionData data) =>
      _runCsvAction(() async {
        final unit = await _pickExportUnit(_recordedUnit(session));
        if (unit == null) return null;
        return shareSessionCsv(
          session: session,
          data: data,
          unit: unit,
          sharePositionOrigin: _shareAnchor(),
        );
      });

  /// The session's recorded display unit (frozen at recording start): the
  /// export picker's preselection. An unrecognizable stored value falls
  /// back to the platform default unit.
  static DisplayUnit _recordedUnit(Session session) =>
      DisplayUnit.values.firstWhere(
        (u) => u.name == session.displayUnit,
        orElse: () => DisplayUnit.mVv,
      );

  /// Ask the user for the export's converted unit (docs/csv-format-v1.md:
  /// one file, one unit, chosen by the user), preselected to [initial].
  /// Returns null when cancelled — the caller stays silent then.
  Future<DisplayUnit?> _pickExportUnit(DisplayUnit initial) {
    return showDialog<DisplayUnit>(
      context: context,
      builder: (ctx) {
        var selected = initial;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Export CSV'),
            content: SingleChildScrollView(
              child: RadioGroup<DisplayUnit>(
                groupValue: selected,
                onChanged: (unit) {
                  if (unit != null) setState(() => selected = unit);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final u in DisplayUnit.values)
                      RadioListTile<DisplayUnit>(
                        value: u,
                        title: Text(u.symbol),
                        subtitle: Text(u.label),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                child: const Text('Export'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Run a CSV download/share action and surface its outcome as a snackbar:
  /// the returned result message, the failure, or nothing when the user
  /// cancelled (a null message).
  Future<void> _runCsvAction(Future<String?> Function() action) async {
    String? message;
    Object? error;
    try {
      message = await action();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV export failed: $error')));
    } else if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Anchor rect for the iPad share popover (the whole screen when invoked
  /// from the app-bar menu or the button row).
  Rect? _shareAnchor() {
    final box = context.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null;
  }
}

// -- Load state --

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
