import 'package:material_ui/material_ui.dart';

import '../analysis/test_catalog.dart';
import '../analysis/test_def.dart';
import '../widgets/middle_click_autoscroll.dart';
import '../widgets/section_header.dart';
import '../widgets/wide_layout.dart';
import 'test_preflight_screen.dart';

/// The Tests tab: a browse-only catalog. Browsing works offline; a run
/// refuses loudly at the runner if no plate is streaming.
class TestsTab extends StatefulWidget {
  const TestsTab({super.key});

  @override
  State<TestsTab> createState() => _TestsTabState();
}

class _TestsTabState extends State<TestsTab> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => MiddleClickAutoscroll(
          controller: _scrollController,
          child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: contentSideInset(constraints.maxWidth),
              vertical: 16,
            ),
            children: [
              Text('Tests', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),

              const SectionHeader('Force plate tests'),
              const SizedBox(height: 8),

              for (final def in testCatalog) _TestCard(def: def),
            ],
          ),
        ),
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
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Icon(switch (def.family) {
            TestFamily.gait => Icons.directions_walk,
            TestFamily.sway => Icons.balance,
            TestFamily.singleLeg => Icons.accessibility_new,
            TestFamily.isometric => Icons.fitness_center,
            TestFamily.dropJump => Icons.arrow_downward,
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
