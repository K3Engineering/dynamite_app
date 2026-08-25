import 'package:material_ui/material_ui.dart';

/// Shared empty-state placeholder, so empty states look identical.
class EmptyPlaceholder extends StatelessWidget {
  const EmptyPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.action,
    this.color,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  /// Semantic color override for a failure empty state (e.g. the error
  /// color). Without it, the icon is the dim outline role, the title is
  /// primary text, and the hint is secondary text.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: color ?? scheme.outline),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: color ?? scheme.onSurface),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            // Centered: a multi-line hint (e.g. the web unsupported-browser
            // guidance) must not wrap into a left-aligned block under the
            // centered icon/title.
            Text(
              hint!,
              style: TextStyle(color: color ?? scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
