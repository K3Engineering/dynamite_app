import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/app_meta.dart';
import '../services/app_settings.dart';
import '../models/display_unit.dart';
import '../models/session_summary.dart';
import '../services/csv_export.dart';
import '../services/export_delivery.dart';
import '../services/salvage_export.dart';
import '../services/session_data.dart';
import '../services/session_queries.dart';
import '../services/session_storage.dart';
import '../services/share_capability.dart';
import '../utils/format.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import '../widgets/session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/graph_components.dart';
import '../widgets/snackbars.dart';

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

        // The CSV-vs-salvage menu contrast rides on the damage verdict:
        // a loaded session knows it, a failed load can't rule salvage out.
        final damaged = switch (_loadState) {
          _Ready(data: final d?) => !d.damage.isEmpty,
          _ => false,
        };
        final showSalvage = switch (_loadState) {
          _Ready(data: final d?) => d.damage.truncatedAt != null,
          _Failed() => true,
          _ => false,
        };
        final csvSuffix = damaged ? ' (verified data)' : '';

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
                  PopupMenuItem(
                    value: 'download_csv',
                    child: Text('Download CSV$csvSuffix'),
                  ),
                  PopupMenuItem(
                    value: 'share_csv',
                    enabled: fileShareSupportedHere,
                    child: Text(
                      'Share CSV$csvSuffix'
                      '${fileShareSupportedHere ? '' : ' (not supported here)'}',
                    ),
                  ),
                  // Raw samples that failed integrity verification (see
                  // SessionDamage.truncatedAt) — the hand-recovery artifact.
                  // Hidden when the loaded session has nothing salvageable.
                  if (showSalvage)
                    const PopupMenuItem(
                      value: 'salvage_csv',
                      child: Text(salvageExportLabel),
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
          // Storage-integrity damage is surfaced loudly and permanently —
          // the floors in effect (raw-only conversion, gross counts, a
          // truncated extent) must be unmissable next to the data.
          if (!data.damage.isEmpty)
            _DamageBanner(damage: data.damage, sampleRate: data.sampleRate),
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
                    data.maxs[ch] == null
                        ? null
                        : data.converterFor(ch).net(unit, data.maxs[ch]!),
                ],
              ),
              // The amount the session's frozen tare zeroed out (gross at
              // the tare point; 0 for a channel recorded without a tare).
              ChannelStatsRow(
                label: 'Tare offset',
                values: [
                  for (int ch = 0; ch < data.channels.length; ch++)
                    data.converterFor(ch).tareOffset(unit),
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
      case 'salvage_csv':
        // The menu gates its visibility, but the action itself is safe in
        // every load state: it reports when nothing is salvageable.
        await _downloadSalvage(session);
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
        final unit = await _pickExportUnit(
          _recordedUnit(session),
          damage: data.damage,
        );
        if (unit == null) return null;
        final artifact = buildSessionCsvArtifact(
          sessionName: session.name,
          recordedAt: session.createdAt,
          deviceInfoJson: session.deviceInfoJson,
          data: data,
          unit: unit,
          appMeta: appMeta,
        );
        return downloadExport(
          bytes: artifact.bytes,
          fileName: artifact.fileName,
          dialogTitle: 'Download session CSV',
        );
      });

  Future<void> _shareCsv(SessionSummary session, SessionData data) =>
      _runCsvAction(() async {
        final appMeta = context.read<AppMeta>();
        final unit = await _pickExportUnit(
          _recordedUnit(session),
          damage: data.damage,
        );
        if (unit == null) return null;
        final artifact = buildSessionCsvArtifact(
          sessionName: session.name,
          recordedAt: session.createdAt,
          deviceInfoJson: session.deviceInfoJson,
          data: data,
          unit: unit,
          appMeta: appMeta,
        );
        return shareExport(
          bytes: artifact.bytes,
          fileName: artifact.fileName,
          mimeType: artifact.mimeType,
          dialogTitle: 'Share CSV',
          anchor: _shareAnchor(),
        );
      });

  /// Export every decodable sample that failed integrity verification as a
  /// salvage CSV (see salvage_export.dart). Works in every load state —
  /// for a session whose view failed to load it is the only export.
  Future<void> _downloadSalvage(SessionSummary session) =>
      _runCsvAction(() async {
        final appMeta = context.read<AppMeta>();
        return downloadSalvageCsv(
          sessionId: session.id,
          sessionName: session.name,
          appMeta: appMeta,
        );
      });

  /// The session's recorded display unit (frozen at recording start): the
  /// export picker's preselection. An unrecognizable stored value falls
  /// back to the platform default unit.
  static DisplayUnit _recordedUnit(SessionSummary session) =>
      DisplayUnit.fromName(session.displayUnit);

  /// Ask the user for the export's converted unit (docs/csv-format-v1.md:
  /// one file, one unit, chosen by the user), preselected to [initial].
  /// Returns null when cancelled — the caller stays silent then. A damaged
  /// session is exported knowingly: the dialog names the damage and its
  /// consequences for the file (they ride along in its `warnings`
  /// metadata), never blocks the export.
  Future<DisplayUnit?> _pickExportUnit(
    DisplayUnit initial, {
    SessionDamage damage = SessionDamage.none,
  }) {
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
                    if (!damage.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Session data damaged — the CSV carries the details '
                          'in its metadata; converted columns may be blank.'
                          '${damage.truncatedAt != null ? ' Data outside the verified extent is in "$salvageExportLabel".' : ''}',
                        ),
                      ),
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
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'CSV export failed: $error',
      );
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

// -- Damage banner --

/// Persistent banner for a session whose stored data failed integrity
/// checks (see [SessionDamage]): one human line per flag naming the floor
/// in effect. The machine-readable codes stay out of the UI — they are the
/// CSV `warnings` metadata's contract, and this screen always has an exact
/// interpretation.
class _DamageBanner extends StatelessWidget {
  const _DamageBanner({required this.damage, required this.sampleRate});

  final SessionDamage damage;

  /// The session's recorded rate (a session-row scalar, authoritative here
  /// as in the statistics rows) — derives the truncation point's elapsed
  /// time from its sample index.
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session data damaged',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final line in _consequences)
                  Text(line, style: TextStyle(color: scheme.onErrorContainer)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One human line per flag, naming the floor in effect.
  List<String> get _consequences => [
    if (damage.calibration) 'Calibration unknown — raw counts only.',
    if (damage.gapsLost)
      'Dropout positions unknown — some samples may be repeated held values.',
    if (damage.boardMetaLost)
      'Calibration provenance lost — which calibration this session was '
          'recorded under is unknown; conversions are unaffected.',
    if (damage.truncatedAt case final t?)
      'Data truncated at sample ${formatThousands(t)} (${_elapsedAt(t)} of '
          'recording) — later storage failed integrity checks and is '
          'hidden. Available raw via menu → "$salvageExportLabel".',
  ];

  /// The recording time at [sample], whole seconds. Sub-second cuts clamp
  /// to "<1s" — a bare "0s" would read like a UI bug next to the truth.
  String _elapsedAt(int sample) {
    final ms = sample * 1000 ~/ sampleRate;
    if (ms == 0) return '<1s';
    return '≈ ${formatDuration(Duration(milliseconds: ms))}';
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
