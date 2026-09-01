import 'damaged_session.dart';
import 'session_summary.dart';

/// One coherent view of every directory for the Sessions tab. The
/// constructor owns the ordering — the id sorts chronologically, so
/// descending ids IS descending creation order, ties included — and the
/// lookup map; producers pass entries in any order.
class SessionCatalog {
  SessionCatalog({
    required Iterable<SessionSummary> sessions,
    required Iterable<DamagedSession> damaged,
    required Map<String, int> byteSizes,
  }) : sessions = List.unmodifiable(
         [...sessions]..sort((a, b) => _desc(a.id, b.id)),
       ),
       damaged = List.unmodifiable(
         [...damaged]..sort((a, b) => _desc(a.id, b.id)),
       ),
       byteSizes = Map.unmodifiable(byteSizes) {
    _byId = {for (final session in this.sessions) session.id: session};
  }

  static int _desc(String a, String b) => b.compareTo(a);

  final List<SessionSummary> sessions;
  final List<DamagedSession> damaged;
  final Map<String, int> byteSizes;

  late final Map<String, SessionSummary> _byId;

  SessionSummary? session(String id) => _byId[id];
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
