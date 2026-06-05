class SessionModel {
  final int id;
  final String name;
  final DateTime createdAt;
  final int durationMs;
  final int sampleRate;
  final int channelCount;
  final String channelLabels;
  final double peakForceRaw;
  final int peakForceChannel;
  final double calibrationSlope;
  final int calibrationOffset;
  final String notes;
  final int sampleCount;
  final bool isCompleted;

  SessionModel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.durationMs,
    required this.sampleRate,
    required this.channelCount,
    required this.channelLabels,
    required this.peakForceRaw,
    required this.peakForceChannel,
    required this.calibrationSlope,
    required this.calibrationOffset,
    required this.notes,
    required this.sampleCount,
    required this.isCompleted,
  });
}
