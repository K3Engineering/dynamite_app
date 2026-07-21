import 'package:flutter/material.dart';

/// Shared empty-state placeholder: a large dim icon over a title and optional
/// hint, with an optional action widget below (e.g. a Connect button). Used by
/// the Devices, Sessions and Live tabs so empty states look identical.
class EmptyPlaceholder extends StatelessWidget {
  const EmptyPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).colorScheme.outline;
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
            Text(hint!, style: TextStyle(color: dim)),
          ],
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
