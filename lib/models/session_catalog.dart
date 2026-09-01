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
}
