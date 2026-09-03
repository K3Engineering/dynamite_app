import 'dart:js_interop';

import '../models/storage_capacity.dart';

/// Web producer for the storage strip (see `storage_capacity.dart`). The
/// browser's quantitative estimate is unusable — navigator.storage.estimate()
/// reports quota as usage + 10 GiB (static anti-fingerprinting), untethered
/// from free disk space, and Chrome's OPFS usage accounting itself drifts —
/// so the only signal probed is persisted(): the eviction guarantee the
/// strip's warning is keyed to.
///
/// navigator.storage exists only in secure contexts and persisted() can
/// reject (storage disabled, opaque origin) — both report null, the strip
/// hides instead of guessing.

@JS('navigator')
external _WebNavigator get _navigator;

extension type _WebNavigator(JSObject _) implements JSObject {
  external _StorageManager? get storage;
  external String get userAgent;
}

extension type _StorageManager(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> persisted();
}

/// Ignores [usedBytes]: web shows no capacity numbers, so the session-store
/// ledger is unused here (the parameter keeps the signature shared with the
/// native producer).
Future<StorageState?> fetchStorageState({
  required Future<int> Function() usedBytes,
}) async {
  final storage = _navigator.storage;
  if (storage == null) return null;
  try {
    final persisted = (await storage.persisted().toDart).toDart;
    return persisted ? null : const StorageEvictable();
  } catch (_) {
    return null;
  }
}

bool browserMayAutoDeleteSessions() =>
    userAgentMayAutoDelete(_navigator.userAgent);
