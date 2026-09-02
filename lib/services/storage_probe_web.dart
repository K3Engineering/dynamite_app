import 'dart:js_interop';
import 'dart:math' as math;

import '../models/storage_capacity.dart';

/// Web producer for the storage strip (see `storage_capacity.dart`):
/// navigator.storage.estimate() for quota, persisted() for the eviction
/// guarantee, the caller's byte ledger for usage. navigator.storage exists
/// only in secure contexts and estimate() can reject (storage disabled,
/// opaque origin) — both report null so the strip hides instead of showing
/// fiction.

@JS('navigator')
external _WebNavigator get _navigator;

extension type _WebNavigator(JSObject _) implements JSObject {
  external _StorageManager? get storage;
  external String get userAgent;
}

extension type _StorageManager(JSObject _) implements JSObject {
  external JSPromise<_StorageEstimate> estimate();
  external JSPromise<JSBoolean> persisted();
}

extension type _StorageEstimate(JSObject _) implements JSObject {
  external JSNumber get quota;
}

/// Usage comes from the caller's [usedBytes] ledger (the same one the
/// native strip uses), never from estimate(): Chrome's OPFS accounting
/// debits can drift negative (origin maintenance touches files the app
/// never wrote), and the negative int64 renders through a uint32 lens as
/// ~4 GB. estimate()'s quota half is unaffected by that.
Future<StorageCapacity?> fetchStorageCapacity({
  required Future<int> Function() usedBytes,
}) async {
  final storage = _navigator.storage;
  if (storage == null) return null;
  try {
    final estimate = await storage.estimate().toDart;
    final persisted = (await storage.persisted().toDart).toDart;
    final used = await usedBytes();
    final quota = estimate.quota.toDartDouble.round();
    return StorageCapacity(
      usedBytes: used,
      availableBytes: math.max(0, quota - used),
      isPersistent: persisted,
    );
  } catch (_) {
    return null;
  }
}

bool browserMayAutoDeleteSessions() =>
    userAgentMayAutoDelete(_navigator.userAgent);
