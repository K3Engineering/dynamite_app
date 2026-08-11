import 'package:flutter/material.dart';

import '../services/database.dart';
import '../utils/format.dart';

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
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          alignLabelWithHint: maxLines > 1,
        ),
        onSubmitted: maxLines == 1 ? (val) => Navigator.of(ctx).pop(val) : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
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

/// Rename-a-session flow. Callers relying on reactive session streams need
/// no further refresh.
Future<void> renameSessionFlow(
  BuildContext context, {
  required int sessionId,
  required String currentName,
  String title = 'Rename session',
}) async {
  final newName = (await showTextPrompt(
    context,
    title: title,
    label: 'Session name',
    initial: currentName,
  ))?.trim();
  if (newName != null && newName.isNotEmpty) {
    await AppDatabase.instance.renameSession(sessionId, newName);
  }
}

/// Delete-a-session flow. Returns true when the session was deleted (so
/// callers can e.g. pop a detail screen).
Future<bool> deleteSessionFlow(BuildContext context, Session session) async {
  // An empty name would render as Delete ""? — fall back to the shared
  // placeholder title.
  if (!await showDeleteConfirm(
    context,
    what: session.name.isEmpty ? untitledSessionName : session.name,
  )) {
    return false;
  }
  await AppDatabase.instance.deleteSession(session.id);
  return true;
}
