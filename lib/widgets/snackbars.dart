import 'package:material_ui/material_ui.dart';

/// Shows a failure toast in the scheme's error colors. Informational toasts
/// (saved, exported, copied…) stay plain `showSnackBar` calls.
///
/// [persist] keeps the toast up until the user dismisses it (a close icon is
/// shown then) — for failures that must not scroll away unnoticed.
void showErrorSnackBar(
  ScaffoldMessengerState messenger,
  String message, {
  bool persist = false,
}) {
  final colors = Theme.of(messenger.context).colorScheme;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, style: TextStyle(color: colors.onError)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.error,
      persist: persist,
      showCloseIcon: persist,
      closeIconColor: colors.onError,
    ),
  );
}

/// Run one export-style [action] — anything returning a user-facing result
/// message (`export_delivery.dart`, or e.g. a copy-to-clipboard confirmation)
/// — and surface the outcome as a snackbar: the action's message on success,
/// an error toast ('[errorTitle] failed: …') on a throw, nothing when it
/// returns null (the user cancelled).
Future<void> runExportAction(
  BuildContext context,
  Future<String?> Function() action, {
  required String errorTitle,
}) async {
  String? message;
  Object? error;
  try {
    message = await action();
  } catch (e) {
    error = e;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (error != null) {
    showErrorSnackBar(messenger, '$errorTitle failed: $error');
  } else if (message != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
