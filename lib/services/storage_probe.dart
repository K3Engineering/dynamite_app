/// Platform storage probing for the Sessions tab's capacity strip, behind
/// the repo's conditional-import pattern: the web implementation reads
/// navigator.storage (estimate's quota, persisted), the native one reads
/// disk_space_2 free space. Both take usage from the caller's session-store
/// byte ledger. Unsupported platforms (desktop) report null and the strip
/// hides — absence is a first-class result, not an error.
library;

export '../models/storage_capacity.dart';
export 'storage_probe_io.dart'
    if (dart.library.js_interop) 'storage_probe_web.dart';
