import 'dart:async';

/// Serializes async ops FIFO: each op starts only after every previously
/// enqueued op has settled. An op's result and error go to its own caller
/// only — the chain copy swallows errors, so one failed op never blocks or
/// poisons the ones behind it. Not re-entrant by design: an op calling
/// [run] on its own chain just queues behind itself, never deadlocks.
class FutureChain {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() op) {
    final result = _tail.then<T>((_) => op());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
