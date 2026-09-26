import 'package:material_ui/material_ui.dart';

/// Shared dialog helpers: one text prompt and one delete confirmation.

/// Prompt for a single text value. Returns the entered text (which may be
/// empty), or null when cancelled. Single-line prompts submit on Enter;
/// multi-line ones (e.g. notes) confirm via the Save button only.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  int maxLines = 1,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      label: label,
      initial: initial,
      maxLines: maxLines,
    ),
  );
}

/// Stateful so the controller outlives the pop future: `showDialog` resolves
/// when the route pops, but the field stays attached through the exit
/// transition, so disposing there would race a focus/selection change.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.maxLines,
  });

  final String title;
  final String label;
  final String initial;
  final int maxLines;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
          alignLabelWithHint: widget.maxLines > 1,
        ),
        onSubmitted: widget.maxLines == 1
            ? (val) => Navigator.of(context).pop(val)
            : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Ask the user to confirm deleting the session named [what]. Returns true
/// only when confirmed.
Future<bool> showDeleteConfirm(
  BuildContext context, {
  required String what,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete session?'),
      content: Text('Delete "$what"? This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
