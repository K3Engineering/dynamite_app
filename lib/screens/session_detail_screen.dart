import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/app_meta.dart';
import '../models/app_settings.dart';
import '../models/display_unit.dart';
import '../models/session_summary.dart';
import '../services/csv_export.dart';
import '../services/export_delivery.dart';
import '../services/session_data.dart';
import '../services/session_queries.dart';
import '../services/session_storage.dart';
import '../services/share_capability.dart';
import '../utils/format.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import 'session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/graph_components.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final SessionSummary session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  /// Load state of the session's sample data (see [_LoadState]).
  _LoadState _loadState = const _Loading();

  final GraphController _graphCtrl = GraphController();

  /// The session row, reactively: name, notes, duration, and the per-session
  /// channel-visibility set. Edits are written to the DB and surface via
  /// this stream.
  late final Stream<SessionSummary?> _sessionStream;

  @override
  void initState() {
    super.initState();
    _sessionStream = watchSessionSummary(widget.session.id);
    unawaited(_loadData());
  }

  /// Persist a channel-visibility flip; the row stream drives the UI update.
  Future<void> _toggleChannel(SessionSummary session, int index) async {
    final updated = [...session.visibleChannels];
    updated[index] = !updated[index];
    await setSessionVisibleChannels(session.id, updated);
  }

  @override
  void dispose() {
    _graphCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await SessionStorage.loadSession(widget.session.id);
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

    return StreamBuilder<SessionSummary?>(
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
                    enabled: fileShareSupportedHere,
                    child: Text(
                      'Share CSV'
                      '${fileShareSupportedHere ? '' : ' (not supported here)'}',
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
    SessionSummary session,
    SessionData data,
  ) {
    final visibleChannels = session.visibleChannels;
    final channelLabels = session.channelLabels;
    final unit = settings.displayUnit.effective(
      resolveUnitAvailability(data.calibrationFor, [
        for (int i = 0; i < visibleChannels.length; i++)
          if (visibleChannels[i]) i,
      ]),
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
                unawaited(_toggleChannel(session, index)),
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
                unit: settings.displayUnit,
                limitWarningsEnabled: settings.limitWarningsEnabled,
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
                    onPressed: fileShareSupportedHere
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

  Future<void> _onMenuAction(String action, SessionSummary session) async {
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

  Future<void> _showRenameDialog(SessionSummary session) => renameSessionFlow(
    context,
    sessionId: session.id,
    currentName: session.name,
  );

  Future<void> _showNotesDialog(SessionSummary session) async {
    final newNotes = await showTextPrompt(
      context,
      title: 'Edit notes',
      label: 'Notes',
      initial: session.notes,
      maxLines: 5,
    );
    if (newNotes != null) {
      await setSessionNotes(session.id, newNotes);
    }
  }

  Future<void> _deleteAndPop(SessionSummary session) async {
    if (await deleteSessionFlow(
      context,
      sessionId: session.id,
      name: session.name,
    )) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _downloadCsv(SessionSummary session, SessionData data) =>
      _runCsvAction(() async {
        final appMeta = context.read<AppMeta>();
        final unit = await _pickExportUnit(_recordedUnit(session));
        if (unit == null) return null;
        return downloadSessionCsv(
          sessionName: session.name,
          recordedAt: session.createdAt,
          deviceInfoJson: session.deviceInfoJson,
          data: data,
          unit: unit,
          appMeta: appMeta,
        );
      });

  Future<void> _shareCsv(SessionSummary session, SessionData data) =>
      _runCsvAction(() async {
        final appMeta = context.read<AppMeta>();
        final unit = await _pickExportUnit(_recordedUnit(session));
        if (unit == null) return null;
        return shareSessionCsv(
          sessionName: session.name,
          recordedAt: session.createdAt,
          deviceInfoJson: session.deviceInfoJson,
          data: data,
          unit: unit,
          appMeta: appMeta,
          anchor: _shareAnchor(),
        );
      });

  /// The session's recorded display unit (frozen at recording start): the
  /// export picker's preselection. An unrecognizable stored value falls
  /// back to the platform default unit.
  static DisplayUnit _recordedUnit(SessionSummary session) =>
      DisplayUnit.fromName(session.displayUnit);

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
  ShareAnchor? _shareAnchor() {
    final box = context.findRenderObject();
    if (box is! RenderBox) return null;
    final global = box.localToGlobal(Offset.zero);
    final size = box.size;
    return (
      left: global.dx,
      top: global.dy,
      width: size.width,
      height: size.height,
    );
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
