import 'session_store_backend.dart';

Future<SessionFilesBackend> createBackend() {
  throw UnsupportedError('no session-files backend for this platform');
}

void terminateSinkWorker() {}
