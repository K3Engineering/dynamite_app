import 'damaged_session.dart';
import 'session_summary.dart';

class SessionCatalog {
  SessionCatalog({
    required List<SessionSummary> sessions,
    required List<DamagedSession> damaged,
    required Map<String, int> byteSizes,
  }) : sessions = List.unmodifiable(sessions),
       damaged = List.unmodifiable(damaged),
       byteSizes = Map.unmodifiable(byteSizes);

  final List<SessionSummary> sessions;
  final List<DamagedSession> damaged;
  final Map<String, int> byteSizes;

  SessionSummary? session(String id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }
}

sealed class SessionCatalogState {
  const SessionCatalogState();
}

final class SessionCatalogLoading extends SessionCatalogState {
  const SessionCatalogLoading();
}

final class SessionCatalogReady extends SessionCatalogState {
  const SessionCatalogReady(this.catalog);

  final SessionCatalog catalog;
}

final class SessionCatalogFailed extends SessionCatalogState {
  const SessionCatalogFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
