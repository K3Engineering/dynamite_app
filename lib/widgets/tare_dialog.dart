import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../services/app_settings.dart';
import '../services/data_hub.dart';
import '../services/rig_state.dart';

/// Per-channel tare control: each active channel's live value and tare point
/// (both in the current display unit), with TARE/RESET per channel and ALL
/// variants in the actions row. Actions act on the hub directly and the
/// dialog stays open, so the new offset is visible where it was requested.
Future<void> showTareDialog(
  BuildContext context, {
  required DataHub hub,
  required RigState rig,
  required AppSettings settings,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _TareDialog(hub: hub, rig: rig, settings: settings),
  );
}

class _TareDialog extends StatelessWidget {
  final DataHub hub;
  final RigState rig;
  final AppSettings settings;

  const _TareDialog({
    required this.hub,
    required this.rig,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final unit = settings.displayUnit.effective(
      resolveUnitAvailability(
        hub.calibrationFor,
        settings.activeChannelIndices,
      ),
    );
    // The hub notifies per packet; the dialog rebuilds with it so the live
    // column actually reads live and a tare's completion shows in place.
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final channels = settings.activeChannelIndices;
        return AlertDialog(
          title: Text('Tare · ${unit.symbol}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _headerRow(),
              for (final ch in channels) _channelRow(ch, unit),
              if (channels.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No active channels'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: hub.resetTare,
              child: const Text('Reset all'),
            ),
            TextButton(
              onPressed: hub.requestTare,
              child: const Text('Tare all'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _headerRow() {
    return const Row(
      children: [
        SizedBox(width: 88),
        Expanded(child: _HeadCell('Live')),
        Expanded(child: _HeadCell('Tare')),
        // Match the two icon buttons below so headers sit over the values.
        SizedBox(width: 40),
        SizedBox(width: 40),
      ],
    );
  }

  Widget _channelRow(int ch, DisplayUnit unit) {
    String fmt(double? v) => v == null ? '—' : unit.formatValueOnly(v);
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(rig.channelTitles[ch], overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Text(
            fmt(hub.currentValue(ch, unit)),
            textAlign: TextAlign.end,
          ),
        ),
        Expanded(
          child: Text(fmt(hub.tarePoint(ch, unit)), textAlign: TextAlign.end),
        ),
        SizedBox(
          width: 40,
          child: IconButton(
            tooltip: 'Tare this channel',
            onPressed: () => hub.requestTare(channel: ch),
            icon: const Icon(Icons.exposure_zero, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ),
        SizedBox(
          width: 40,
          child: IconButton(
            tooltip: 'Reset this channel',
            onPressed: () => hub.resetTare(channel: ch),
            icon: const Icon(Icons.restart_alt, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }
}

class _HeadCell extends StatelessWidget {
  final String text;
  const _HeadCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.end,
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}
