/// Platform storage probing for the Sessions tab's storage strip, behind
/// the repo's conditional-import pattern: the web implementation reads
/// navigator.storage.persisted(), the native one reads disk_space_2 free
/// space plus the caller's session-store byte ledger for usage. Unsupported
/// platforms (desktop) report null and the strip hides — absence is a
/// first-class result, not an error.
library;

export '../models/storage_capacity.dart';
export 'storage_probe_io.dart'
    if (dart.library.js_interop) 'storage_probe_web.dart';
