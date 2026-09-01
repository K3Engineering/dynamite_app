import 'package:material_ui/material_ui.dart';

/// Full-screen placeholder shown while this tab waits for the primary-tab
/// lock (see services/primary_tab_lock_web.dart). On web, this screen is the
/// entire app until the lock is granted: no services exist behind it, so
/// nothing can touch session storage while it is up. There is deliberately
/// no action button — the way forward is closing the tab that holds the
/// lock; this tab starts automatically when the browser hands the lock over.
class AnotherTabScreen extends StatelessWidget {
  const AnotherTabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tab_outlined,
                size: 48,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                'Dynamite is open in another tab',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Close that tab to use the app here — '
                'this one starts automatically.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
