import 'package:flutter/foundation.dart';

/// Polls [now] whenever any of [sources] notifies and calls [effect] only
/// when the polled value changed since the last poll. Sources like the BLE
/// link manager notify for many unrelated reasons (RSSI polls, telemetry),
/// so a listener that needs react-on-transition semantics must derive the
/// transition itself: poll the real predicate, compare against the last
/// value, apply the delta only.
///
/// The last value starts at [seed], or one poll at construction when no
/// seed is given (no [effect] fires until a later poll sees a change).
/// [check] forces a poll, for state that changes without a notification.
class EdgeWatcher<T> {
  EdgeWatcher({
    required List<Listenable> sources,
    required T Function() now,
    required void Function(T value) effect,
    T? seed,
  }) : _sources = sources,
       _now = now,
       _effect = effect,
       _last = seed ?? now() {
    for (final source in _sources) {
      source.addListener(check);
    }
  }

  final List<Listenable> _sources;
  final T Function() _now;
  final void Function(T value) _effect;
  T _last;

  /// Poll [now] now; runs [effect] if the value moved since the last poll.
  void check() {
    final value = _now();
    if (value == _last) return;
    _last = value;
    _effect(value);
  }

  void dispose() {
    for (final source in _sources) {
      source.removeListener(check);
    }
  }
}
