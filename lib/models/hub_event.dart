import 'package:meta/meta.dart';

/// Hub lifecycle/data events for observers that need exact deltas: the
/// recording path (which samples landed) and stream-boundary tracking (the
/// decoder's continuity reset, per-view pan/zoom reset). Consumers subscribe
/// to one listener slot and switch exhaustively on the event class, instead
/// of one bespoke listener list per concern.
///
/// These are NOT the UI's rebuild signal — that stays `ChangeNotifier` on
/// `DataHub` itself (the live graphs want per-packet rebuilds).
@immutable
sealed class HubEvent {
  const new();
}

/// [count] samples were appended starting at absolute index [startIdx] (one
/// decoded packet's worth — emitted by `DataHub.commitBatch`).
final class const HubBatchAppended(final int startIdx, final int count)
    extends HubEvent;

/// A new device stream just reset the hub (`DataHub.clear`): every per-stream
/// accumulation restarted, so views must drop stale windows and protocol
/// state must forget the previous stream's counters.
final class const HubCleared() extends HubEvent;
