import 'package:material_ui/material_ui.dart';

import '../services/session_queries.dart';
import '../utils/format.dart';
import '../widgets/dialogs.dart';

/// Session-level dialog flows shared by the Sessions tab, the session
/// detail screen, and the Live tab's rename action. The generic prompts
/// live in `widgets/dialogs.dart`; the database calls go through
/// `services/session_queries.dart`, so the widget layer never sees the DB.

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
    await renameSession(sessionId, newName);
  }
}

/// Delete-a-session flow. Returns true when the session was deleted (so
/// callers can e.g. pop a detail screen).
Future<bool> deleteSessionFlow(
  BuildContext context, {
  required int sessionId,
  required String name,
}) async {
  // An empty name would render as Delete ""? — fall back to the shared
  // placeholder title.
  if (!await showDeleteConfirm(
    context,
    what: name.isEmpty ? untitledSessionName : name,
  )) {
    return false;
  }
  await deleteSession(sessionId);
  return true;
}
