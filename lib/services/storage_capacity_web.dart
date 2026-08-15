import 'dart:js_interop';
import 'dart:math' as math;

import '../models/storage_capacity.dart';

/// Web producer for the storage strip (see `storage_capacity.dart`):
/// navigator.storage.estimate() for usage/quota, persisted() for the
/// eviction guarantee. navigator.storage exists only in secure contexts and
/// estimate() can reject (storage disabled, opaque origin) — both report
/// null so the strip hides instead of showing fiction.

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
  external JSNumber get usage;
  external JSNumber get quota;
}

Future<StorageCapacity?> fetchStorageCapacity() async {
  final storage = _navigator.storage;
  if (storage == null) return null;
  try {
    final estimate = await storage.estimate().toDart;
    final persisted = (await storage.persisted().toDart).toDart;
    final used = estimate.usage.toDartDouble.round();
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
