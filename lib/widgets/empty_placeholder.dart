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

  /// Color override for the icon/title/hint (e.g. an error color when the
  /// empty state reports a failure). Defaults to the dim outline color.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dim = color ?? Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: dim),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: dim),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            // Centered: a multi-line hint (e.g. the web unsupported-browser
            // guidance) must not wrap into a left-aligned block under the
            // centered icon/title.
            Text(
              hint!,
              style: TextStyle(color: dim),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
