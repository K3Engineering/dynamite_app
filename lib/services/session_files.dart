/// Resolves the platform's default sessions root and its backend
/// (conditional import: dart:io on native, the OPFS sink worker on web).
library;

import 'session_store_backend.dart';
import 'session_files_stub.dart'
    if (dart.library.io) 'session_files_io.dart'
    if (dart.library.js_interop) 'session_files_web.dart'
    as impl;

Future<SessionFilesBackend> createDefaultSessionFilesBackend() =>
    impl.createBackend();

/// Debug-only hot-restart hook (web): kill the sink worker so its sync
/// access handles release their exclusive locks before the next generation
/// opens the same session files. No-op off web.
void terminateSessionSinkWorker() => impl.terminateSinkWorker();
