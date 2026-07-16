/// Non-web implementation of the hot-restart cleanup hook: a no-op.
///
/// On native platforms a hot restart tears down the whole Dart isolate, so
/// nothing from the previous generation survives and no cleanup is needed.
/// See `hot_restart_cleanup_web.dart` for the web story and the conditional
/// import site in `main.dart`.
library;

void runPreviousHotRestartCleanup() {}

void registerHotRestartCleanup(void Function() cleanup) {}

void installHotRestartErrorFilter(void Function() onViewDisposed) {}
