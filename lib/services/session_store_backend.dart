import 'dart:typed_data';

/// One session directory's files: [sessionJournalFile] (append-only JSONL:
/// line 1 the header, later lines display-state snapshots), [sessionDataFile]
/// (append-only packed int32-LE frames, gap sentinels in-band) and
/// [sessionFinalFile] (an empty marker — existence IS the completed bit).
/// Two append-only files and one write-once marker; nothing is rewritten in
/// place, so damage is tail-only: loaders truncate to complete records and a
/// torn trailing journal line costs at most that one edit.
const sessionJournalFile = 'meta';
const sessionDataFile = 'data.raw';
const sessionFinalFile = 'final';

/// An open recording sink for one session directory: the packed frames of
/// [sessionDataFile]'s tail, appended exactly once per accepted packet, with
/// the append's durability covered before the ack returns.
abstract interface class SessionDataSink {
  /// The session id (the directory's name).
  String get id;

  /// Append [bytes] (whole frames, gap sentinels already filled by the
  /// writer) and flush; returns the file's byte length after this append —
  /// the ack the finalize-time write count check compares against.
  Future<int> append(Uint8List bytes);

  /// Release the open handle. Called once at finalize/abort.
  Future<void> close();
}

/// The primitives the per-session file layout needs, one seam behind which
/// live the native (dart:io) and web (OPFS + sink worker) implementations.
/// Everything semantic — journal parsing, damaged-entry verdicts, recovery —
/// is store-side; implementations are transport-only and carry no rules.
abstract interface class SessionFilesBackend {
  /// Create the session directory [id] (which MUST NOT already exist — a
  /// collision is two recordings merged into one directory and throws), its
  /// journal with [metaBytes] as line 1, and [sessionDataFile] with
  /// [firstData] — all flushed — and hand back the open append sink.
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  );

  /// Every directory name in the sessions root (empty when the root doesn't
  /// exist yet).
  Future<List<String>> listDirIds();

  /// The journal's full bytes, or null when the file is absent.
  Future<Uint8List?> readJournal(String id);

  /// data.raw's full bytes, or null when the file is absent.
  Future<Uint8List?> readData(String id);

  /// data.raw's byte length, or 0 when the file is absent.
  Future<int> dataByteLength(String id);

  /// Whether the [sessionFinalFile] marker exists (existence IS the bit;
  /// content is never read).
  Future<bool> isFinalized(String id);

  /// Write the empty [sessionFinalFile] marker.
  Future<void> touchFinal(String id);

  /// Cut the journal to exactly [bytes] — the edit path's one non-append
  /// mutation, discarding a torn tail before the next edit line lands.
  Future<void> truncateJournal(String id, int bytes);

  /// Append [bytes] (one encoded journal line) at the journal's EOF + flush.
  Future<void> appendJournal(String id, Uint8List bytes);

  /// Delete the session directory wholesale. The only destructive operation
  /// in the store; only ever driven by a user gesture.
  Future<void> delete(String id);

  /// Total bytes of everything under the sessions root (0 when absent) —
  /// the native storage strip's "used" number.
  Future<int> totalBytes();
}
