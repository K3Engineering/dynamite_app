import 'package:material_ui/material_ui.dart';

/// Shows a failure toast in the scheme's error colors. Informational toasts
/// (saved, exported, copied…) go through [showNoticeSnackBar].
///
/// [persist] keeps the toast up until the user dismisses it — for failures
/// that must not scroll away unnoticed.
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
      showCloseIcon: true,
      closeIconColor: colors.onError,
    ),
  );
}

/// Shows an informational toast. This is the app's one notice shape: floating
/// (margined and rounded, so it reads as a transient overlay rather than a
/// full-width banner) with a close icon (so "dismissable" is visible, not just
/// a swipe nobody can see). [action] adds a labelled action; the toast still
/// auto-dismisses unless [persist].
///
/// Every informational snackbar goes through here or [showErrorSnackBar] so the
/// shape cannot drift call by call.
void showNoticeSnackBar(
  ScaffoldMessengerState messenger,
  String message, {
  SnackBarAction? action,
  bool persist = false,
}) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      action: action,
      persist: persist,
      showCloseIcon: true,
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
    showNoticeSnackBar(messenger, message);
  }
}
