import 'package:flutter/material.dart';

/// Section header rendered as a label centered inside a divider line:
/// ──────── label ────────
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}
