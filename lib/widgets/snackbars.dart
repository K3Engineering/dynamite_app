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
