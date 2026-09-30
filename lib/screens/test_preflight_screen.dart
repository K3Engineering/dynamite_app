import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../analysis/test_def.dart';
import '../models/bt_scan.dart';
import '../services/ble_link_manager.dart';
import 'test_runner_screen.dart';

/// Pre-flight for one test: what it measures, how to set up, and an optional
/// subject label. Begin is disabled until a plate is streaming.
class TestPreflightScreen extends StatefulWidget {
  const TestPreflightScreen({super.key, required this.def});

  final TestDef def;

  @override
  State<TestPreflightScreen> createState() => _TestPreflightScreenState();
}

class _TestPreflightScreenState extends State<TestPreflightScreen> {
  final TextEditingController _person = TextEditingController();

  @override
  void dispose() {
    _person.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final def = widget.def;
    final streaming = context.select<BleLinkManager, bool>(
      (l) => l.linkState == BtLinkState.streaming,
    );
    return Scaffold(
      appBar: AppBar(title: Text(def.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            def.category.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.secondary,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(def.description, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 20),
          Text('Setup', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final line in def.instructions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.circle, size: 6),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text('How the run goes', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final line in _flowLines(def))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.circle, size: 6),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _person,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Person (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          if (!streaming)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Connect a device to run tests.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          FilledButton.icon(
            onPressed: streaming ? _begin : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Begin'),
          ),
        ],
      ),
    );
  }

  void _begin() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TestRunnerScreen(def: widget.def, person: _person.text),
      ),
    );
  }
}

/// What the runner will ask of the subject, in order — the zeroing and
/// weigh-in choreography the per-test instructions don't cover.
List<String> _flowLines(TestDef def) => [
  'Step off: the plate zeroes itself.',
  switch ((def.mold, def.arming)) {
    (TestMold.repCount, TestArming.unloaded) =>
      'Step on and stand still for the weigh-in, then move to the box. '
          'Each landing on the plate is a rep.',
    (TestMold.repCount, _) =>
      'Step on and stand still for the weigh-in. Jump when told, and stand '
          'still between reps — that re-arms the next one.',
    (TestMold.timedCapture, _) =>
      'Step on and stand still for the weigh-in. The windows then run back '
          'to back; a beep marks each change.',
    (TestMold.freePass, _) =>
      'Step on and stand still for the weigh-in, then step off and start '
          'walking by. Press "Stop and save" when done.',
  },
];
