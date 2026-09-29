import 'package:material_ui/material_ui.dart';

import '../analysis/test_catalog.dart';
import '../analysis/test_def.dart';
import '../widgets/section_header.dart';
import 'test_preflight_screen.dart';

/// The Tests tab: a browse-only catalog. Browsing works offline; a run
/// refuses loudly at the runner if no plate is streaming.
class TestsTab extends StatelessWidget {
  const TestsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Tests'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [for (final def in testCatalog) _TestCard(def: def)],
            ),
          ),
        ],
      ),
    );
  }
}

class _TestCard extends StatelessWidget {
  const _TestCard({required this.def});

  final TestDef def;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Icon(switch (def.id) {
            'gait' => Icons.directions_walk,
            'romberg' => Icons.balance,
            _ => Icons.speed,
          }),
        ),
        title: Text(def.name),
        subtitle: Text(def.description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TestPreflightScreen(def: def),
          ),
        ),
      ),
    );
  }
}
