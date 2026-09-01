/// Native implementation of the primary-tab gate: a no-op.
///
/// A native app instance is a single process — there is no second tab that
/// could race this one for the session files, so the process is always
/// primary. See `primary_tab_lock_web.dart` for the web story and the
/// conditional import site in `main.dart`.
library;

/// Resolves immediately on native: always primary.
Future<void> acquirePrimaryTabLock() => Future.value();

/// Hot-restart release hook — nothing to release on native.
void releasePrimaryTabLock() {}
