import 'package:flutter/material.dart';

/// Section header rendered as a label centered inside a divider line:
/// ──────── label ────────
///
/// When [trailing] is provided it is pinned to the far right of the row,
/// after the right divider — used by the Devices tab to attach the Scan
/// button to the "BLE devices" header. Other call sites omit it and keep the
/// original symmetric look.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});

  final String label;

  /// Optional right-aligned widget (e.g. an action button) rendered after the
  /// right divider.
  final Widget? trailing;

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
        if (trailing != null) ...[const SizedBox(width: 4), trailing!],
      ],
    );
  }
}
