import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm, Value;

import '../models/session_model.dart';
import 'database.dart';

abstract class SessionRepository {
  static final SessionRepository instance = DriftSessionRepository(AppDatabase.instance);

  Future<int> createSession({
    required String name,
    required int sampleRate,
    required int channelCount,
    required String channelLabels,
    required double calibrationSlope,
    required int calibrationOffset,
    required String notes,
  });

  Future<void> updateSessionCompletion({
    required int id,
    required int sampleCount,
    required int durationMs,
    required double peakForceRaw,
    required int peakForceChannel,
    required bool isCompleted,
  });

  Future<void> updateSessionName(int id, String newName);
  Future<void> updateSessionNotes(int id, String newNotes);
  Future<void> deleteSession(int id);
  Future<SessionModel?> getSessionById(int id);
  Stream<List<SessionModel>> watchAllSessions();
  Future<List<SessionModel>> getIncompleteSessions();

  Future<void> writeChunk(int sessionId, int chunkIndex, Uint8List data);
  Future<List<Uint8List>> getSessionChunks(int sessionId);
}

class DriftSessionRepository implements SessionRepository {
  final AppDatabase _db;

  DriftSessionRepository(this._db);

  SessionModel _map(Session s) {
    return SessionModel(
      id: s.id,
      name: s.name,
      createdAt: s.createdAt,
      durationMs: s.durationMs,
      sampleRate: s.sampleRate,
      channelCount: s.channelCount,
      channelLabels: s.channelLabels,
      peakForceRaw: s.peakForceRaw,
      peakForceChannel: s.peakForceChannel,
      calibrationSlope: s.calibrationSlope,
      calibrationOffset: s.calibrationOffset,
      notes: s.notes,
      sampleCount: s.sampleCount,
      isCompleted: s.isCompleted,
    );
  }

  @override
  Future<int> createSession({
    required String name,
    required int sampleRate,
    required int channelCount,
    required String channelLabels,
    required double calibrationSlope,
    required int calibrationOffset,
    required String notes,
  }) async {
    return _db.insertSession(
      SessionsCompanion.insert(
        name: Value(name),
        createdAt: DateTime.now(),
        sampleRate: Value(sampleRate),
        channelCount: Value(channelCount),
        channelLabels: Value(channelLabels),
        calibrationSlope: Value(calibrationSlope),
        calibrationOffset: Value(calibrationOffset),
        notes: Value(notes),
        isCompleted: const Value(false),
      ),
    );
  }

  @override
  Future<void> updateSessionCompletion({
    required int id,
    required int sampleCount,
    required int durationMs,
    required double peakForceRaw,
    required int peakForceChannel,
    required bool isCompleted,
  }) async {
    await _db.updateSession(
      id,
      SessionsCompanion(
        sampleCount: Value(sampleCount),
        durationMs: Value(durationMs),
        peakForceRaw: Value(peakForceRaw),
        peakForceChannel: Value(peakForceChannel),
        isCompleted: Value(isCompleted),
      ),
    );
  }

  @override
  Future<void> updateSessionName(int id, String newName) async {
    await _db.updateSession(id, SessionsCompanion(name: Value(newName)));
  }

  @override
  Future<void> updateSessionNotes(int id, String newNotes) async {
    await _db.updateSession(id, SessionsCompanion(notes: Value(newNotes)));
  }

  @override
  Future<void> deleteSession(int id) async {
    await _db.deleteSession(id);
  }

  @override
  Future<SessionModel?> getSessionById(int id) async {
    final session = await _db.sessionById(id);
    if (session == null) return null;
    return _map(session);
  }

  @override
  Stream<List<SessionModel>> watchAllSessions() {
    return _db.watchAllSessions().map((sessions) => sessions.map(_map).toList());
  }

  @override
  Future<List<SessionModel>> getIncompleteSessions() async {
    final incomplete = await (_db.select(_db.sessions)
          ..where((t) => t.isCompleted.equals(false)))
        .get();
    return incomplete.map(_map).toList();
  }

  @override
  Future<void> writeChunk(int sessionId, int chunkIndex, Uint8List data) async {
    await _db.into(_db.sessionChunks).insert(
      SessionChunksCompanion.insert(
        sessionId: sessionId,
        chunkIndex: chunkIndex,
        data: data,
      ),
    );
  }

  @override
  Future<List<Uint8List>> getSessionChunks(int sessionId) async {
    final chunks = await (_db.select(_db.sessionChunks)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm(expression: t.chunkIndex)]))
        .get();
    return chunks.map((c) => c.data).toList();
  }
}
