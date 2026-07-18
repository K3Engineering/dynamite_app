// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $SessionsTable extends Sessions with TableInfo<$SessionsTable, Session> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sampleRateMeta = const VerificationMeta(
    'sampleRate',
  );
  @override
  late final GeneratedColumn<int> sampleRate = GeneratedColumn<int>(
    'sample_rate',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1000),
  );
  static const VerificationMeta _channelCountMeta = const VerificationMeta(
    'channelCount',
  );
  @override
  late final GeneratedColumn<int> channelCount = GeneratedColumn<int>(
    'channel_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(2),
  );
  static const VerificationMeta _channelLabelsMeta = const VerificationMeta(
    'channelLabels',
  );
  @override
  late final GeneratedColumn<String> channelLabels = GeneratedColumn<String>(
    'channel_labels',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('["Load Cell 1","Load Cell 2"]'),
  );
  static const VerificationMeta _taresMeta = const VerificationMeta('tares');
  @override
  late final GeneratedColumn<String> tares = GeneratedColumn<String>(
    'tares',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _peakForceRawMeta = const VerificationMeta(
    'peakForceRaw',
  );
  @override
  late final GeneratedColumn<double> peakForceRaw = GeneratedColumn<double>(
    'peak_force_raw',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _peakForceChannelMeta = const VerificationMeta(
    'peakForceChannel',
  );
  @override
  late final GeneratedColumn<int> peakForceChannel = GeneratedColumn<int>(
    'peak_force_channel',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _calibrationSlopeMeta = const VerificationMeta(
    'calibrationSlope',
  );
  @override
  late final GeneratedColumn<double> calibrationSlope = GeneratedColumn<double>(
    'calibration_slope',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0001117587),
  );
  static const VerificationMeta _calibrationOffsetMeta = const VerificationMeta(
    'calibrationOffset',
  );
  @override
  late final GeneratedColumn<int> calibrationOffset = GeneratedColumn<int>(
    'calibration_offset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sampleCountMeta = const VerificationMeta(
    'sampleCount',
  );
  @override
  late final GeneratedColumn<int> sampleCount = GeneratedColumn<int>(
    'sample_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isCompletedMeta = const VerificationMeta(
    'isCompleted',
  );
  @override
  late final GeneratedColumn<bool> isCompleted = GeneratedColumn<bool>(
    'is_completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_completed" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _gapsMeta = const VerificationMeta('gaps');
  @override
  late final GeneratedColumn<String> gaps = GeneratedColumn<String>(
    'gaps',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _visibleChannelsMeta = const VerificationMeta(
    'visibleChannels',
  );
  @override
  late final GeneratedColumn<String> visibleChannels = GeneratedColumn<String>(
    'visible_channels',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[true,true,true,true]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    createdAt,
    durationMs,
    sampleRate,
    channelCount,
    channelLabels,
    tares,
    peakForceRaw,
    peakForceChannel,
    calibrationSlope,
    calibrationOffset,
    notes,
    sampleCount,
    isCompleted,
    gaps,
    visibleChannels,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Session> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('sample_rate')) {
      context.handle(
        _sampleRateMeta,
        sampleRate.isAcceptableOrUnknown(data['sample_rate']!, _sampleRateMeta),
      );
    }
    if (data.containsKey('channel_count')) {
      context.handle(
        _channelCountMeta,
        channelCount.isAcceptableOrUnknown(
          data['channel_count']!,
          _channelCountMeta,
        ),
      );
    }
    if (data.containsKey('channel_labels')) {
      context.handle(
        _channelLabelsMeta,
        channelLabels.isAcceptableOrUnknown(
          data['channel_labels']!,
          _channelLabelsMeta,
        ),
      );
    }
    if (data.containsKey('tares')) {
      context.handle(
        _taresMeta,
        tares.isAcceptableOrUnknown(data['tares']!, _taresMeta),
      );
    }
    if (data.containsKey('peak_force_raw')) {
      context.handle(
        _peakForceRawMeta,
        peakForceRaw.isAcceptableOrUnknown(
          data['peak_force_raw']!,
          _peakForceRawMeta,
        ),
      );
    }
    if (data.containsKey('peak_force_channel')) {
      context.handle(
        _peakForceChannelMeta,
        peakForceChannel.isAcceptableOrUnknown(
          data['peak_force_channel']!,
          _peakForceChannelMeta,
        ),
      );
    }
    if (data.containsKey('calibration_slope')) {
      context.handle(
        _calibrationSlopeMeta,
        calibrationSlope.isAcceptableOrUnknown(
          data['calibration_slope']!,
          _calibrationSlopeMeta,
        ),
      );
    }
    if (data.containsKey('calibration_offset')) {
      context.handle(
        _calibrationOffsetMeta,
        calibrationOffset.isAcceptableOrUnknown(
          data['calibration_offset']!,
          _calibrationOffsetMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('sample_count')) {
      context.handle(
        _sampleCountMeta,
        sampleCount.isAcceptableOrUnknown(
          data['sample_count']!,
          _sampleCountMeta,
        ),
      );
    }
    if (data.containsKey('is_completed')) {
      context.handle(
        _isCompletedMeta,
        isCompleted.isAcceptableOrUnknown(
          data['is_completed']!,
          _isCompletedMeta,
        ),
      );
    }
    if (data.containsKey('gaps')) {
      context.handle(
        _gapsMeta,
        gaps.isAcceptableOrUnknown(data['gaps']!, _gapsMeta),
      );
    }
    if (data.containsKey('visible_channels')) {
      context.handle(
        _visibleChannelsMeta,
        visibleChannels.isAcceptableOrUnknown(
          data['visible_channels']!,
          _visibleChannelsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Session map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Session(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      sampleRate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sample_rate'],
      )!,
      channelCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_count'],
      )!,
      channelLabels: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_labels'],
      )!,
      tares: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tares'],
      )!,
      peakForceRaw: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}peak_force_raw'],
      )!,
      peakForceChannel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}peak_force_channel'],
      )!,
      calibrationSlope: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}calibration_slope'],
      )!,
      calibrationOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}calibration_offset'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      sampleCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sample_count'],
      )!,
      isCompleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_completed'],
      )!,
      gaps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}gaps'],
      )!,
      visibleChannels: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}visible_channels'],
      )!,
    );
  }

  @override
  $SessionsTable createAlias(String alias) {
    return $SessionsTable(attachedDatabase, alias);
  }
}

class Session extends DataClass implements Insertable<Session> {
  final int id;
  final String name;
  final DateTime createdAt;
  final int durationMs;
  final int sampleRate;
  final int channelCount;
  final String channelLabels;
  final String tares;
  final double peakForceRaw;
  final int peakForceChannel;
  final double calibrationSlope;
  final int calibrationOffset;
  final String notes;
  final int sampleCount;
  final bool isCompleted;

  /// Dropped-sample ranges as JSON `[[start,end],...]`, session-relative,
  /// half-open. The chunk data holds held values across these ranges.
  final String gaps;

  /// Which channels are shown in the session detail view, as a JSON bool
  /// list. Initialized from the live view's channel selection at recording
  /// time; afterwards it is per-session and independent of the live view.
  final String visibleChannels;
  const Session({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.durationMs,
    required this.sampleRate,
    required this.channelCount,
    required this.channelLabels,
    required this.tares,
    required this.peakForceRaw,
    required this.peakForceChannel,
    required this.calibrationSlope,
    required this.calibrationOffset,
    required this.notes,
    required this.sampleCount,
    required this.isCompleted,
    required this.gaps,
    required this.visibleChannels,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['duration_ms'] = Variable<int>(durationMs);
    map['sample_rate'] = Variable<int>(sampleRate);
    map['channel_count'] = Variable<int>(channelCount);
    map['channel_labels'] = Variable<String>(channelLabels);
    map['tares'] = Variable<String>(tares);
    map['peak_force_raw'] = Variable<double>(peakForceRaw);
    map['peak_force_channel'] = Variable<int>(peakForceChannel);
    map['calibration_slope'] = Variable<double>(calibrationSlope);
    map['calibration_offset'] = Variable<int>(calibrationOffset);
    map['notes'] = Variable<String>(notes);
    map['sample_count'] = Variable<int>(sampleCount);
    map['is_completed'] = Variable<bool>(isCompleted);
    map['gaps'] = Variable<String>(gaps);
    map['visible_channels'] = Variable<String>(visibleChannels);
    return map;
  }

  SessionsCompanion toCompanion(bool nullToAbsent) {
    return SessionsCompanion(
      id: Value(id),
      name: Value(name),
      createdAt: Value(createdAt),
      durationMs: Value(durationMs),
      sampleRate: Value(sampleRate),
      channelCount: Value(channelCount),
      channelLabels: Value(channelLabels),
      tares: Value(tares),
      peakForceRaw: Value(peakForceRaw),
      peakForceChannel: Value(peakForceChannel),
      calibrationSlope: Value(calibrationSlope),
      calibrationOffset: Value(calibrationOffset),
      notes: Value(notes),
      sampleCount: Value(sampleCount),
      isCompleted: Value(isCompleted),
      gaps: Value(gaps),
      visibleChannels: Value(visibleChannels),
    );
  }

  factory Session.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Session(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      sampleRate: serializer.fromJson<int>(json['sampleRate']),
      channelCount: serializer.fromJson<int>(json['channelCount']),
      channelLabels: serializer.fromJson<String>(json['channelLabels']),
      tares: serializer.fromJson<String>(json['tares']),
      peakForceRaw: serializer.fromJson<double>(json['peakForceRaw']),
      peakForceChannel: serializer.fromJson<int>(json['peakForceChannel']),
      calibrationSlope: serializer.fromJson<double>(json['calibrationSlope']),
      calibrationOffset: serializer.fromJson<int>(json['calibrationOffset']),
      notes: serializer.fromJson<String>(json['notes']),
      sampleCount: serializer.fromJson<int>(json['sampleCount']),
      isCompleted: serializer.fromJson<bool>(json['isCompleted']),
      gaps: serializer.fromJson<String>(json['gaps']),
      visibleChannels: serializer.fromJson<String>(json['visibleChannels']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'durationMs': serializer.toJson<int>(durationMs),
      'sampleRate': serializer.toJson<int>(sampleRate),
      'channelCount': serializer.toJson<int>(channelCount),
      'channelLabels': serializer.toJson<String>(channelLabels),
      'tares': serializer.toJson<String>(tares),
      'peakForceRaw': serializer.toJson<double>(peakForceRaw),
      'peakForceChannel': serializer.toJson<int>(peakForceChannel),
      'calibrationSlope': serializer.toJson<double>(calibrationSlope),
      'calibrationOffset': serializer.toJson<int>(calibrationOffset),
      'notes': serializer.toJson<String>(notes),
      'sampleCount': serializer.toJson<int>(sampleCount),
      'isCompleted': serializer.toJson<bool>(isCompleted),
      'gaps': serializer.toJson<String>(gaps),
      'visibleChannels': serializer.toJson<String>(visibleChannels),
    };
  }

  Session copyWith({
    int? id,
    String? name,
    DateTime? createdAt,
    int? durationMs,
    int? sampleRate,
    int? channelCount,
    String? channelLabels,
    String? tares,
    double? peakForceRaw,
    int? peakForceChannel,
    double? calibrationSlope,
    int? calibrationOffset,
    String? notes,
    int? sampleCount,
    bool? isCompleted,
    String? gaps,
    String? visibleChannels,
  }) => Session(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    durationMs: durationMs ?? this.durationMs,
    sampleRate: sampleRate ?? this.sampleRate,
    channelCount: channelCount ?? this.channelCount,
    channelLabels: channelLabels ?? this.channelLabels,
    tares: tares ?? this.tares,
    peakForceRaw: peakForceRaw ?? this.peakForceRaw,
    peakForceChannel: peakForceChannel ?? this.peakForceChannel,
    calibrationSlope: calibrationSlope ?? this.calibrationSlope,
    calibrationOffset: calibrationOffset ?? this.calibrationOffset,
    notes: notes ?? this.notes,
    sampleCount: sampleCount ?? this.sampleCount,
    isCompleted: isCompleted ?? this.isCompleted,
    gaps: gaps ?? this.gaps,
    visibleChannels: visibleChannels ?? this.visibleChannels,
  );
  Session copyWithCompanion(SessionsCompanion data) {
    return Session(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      sampleRate: data.sampleRate.present
          ? data.sampleRate.value
          : this.sampleRate,
      channelCount: data.channelCount.present
          ? data.channelCount.value
          : this.channelCount,
      channelLabels: data.channelLabels.present
          ? data.channelLabels.value
          : this.channelLabels,
      tares: data.tares.present ? data.tares.value : this.tares,
      peakForceRaw: data.peakForceRaw.present
          ? data.peakForceRaw.value
          : this.peakForceRaw,
      peakForceChannel: data.peakForceChannel.present
          ? data.peakForceChannel.value
          : this.peakForceChannel,
      calibrationSlope: data.calibrationSlope.present
          ? data.calibrationSlope.value
          : this.calibrationSlope,
      calibrationOffset: data.calibrationOffset.present
          ? data.calibrationOffset.value
          : this.calibrationOffset,
      notes: data.notes.present ? data.notes.value : this.notes,
      sampleCount: data.sampleCount.present
          ? data.sampleCount.value
          : this.sampleCount,
      isCompleted: data.isCompleted.present
          ? data.isCompleted.value
          : this.isCompleted,
      gaps: data.gaps.present ? data.gaps.value : this.gaps,
      visibleChannels: data.visibleChannels.present
          ? data.visibleChannels.value
          : this.visibleChannels,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Session(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('sampleRate: $sampleRate, ')
          ..write('channelCount: $channelCount, ')
          ..write('channelLabels: $channelLabels, ')
          ..write('tares: $tares, ')
          ..write('peakForceRaw: $peakForceRaw, ')
          ..write('peakForceChannel: $peakForceChannel, ')
          ..write('calibrationSlope: $calibrationSlope, ')
          ..write('calibrationOffset: $calibrationOffset, ')
          ..write('notes: $notes, ')
          ..write('sampleCount: $sampleCount, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('gaps: $gaps, ')
          ..write('visibleChannels: $visibleChannels')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    createdAt,
    durationMs,
    sampleRate,
    channelCount,
    channelLabels,
    tares,
    peakForceRaw,
    peakForceChannel,
    calibrationSlope,
    calibrationOffset,
    notes,
    sampleCount,
    isCompleted,
    gaps,
    visibleChannels,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Session &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.durationMs == this.durationMs &&
          other.sampleRate == this.sampleRate &&
          other.channelCount == this.channelCount &&
          other.channelLabels == this.channelLabels &&
          other.tares == this.tares &&
          other.peakForceRaw == this.peakForceRaw &&
          other.peakForceChannel == this.peakForceChannel &&
          other.calibrationSlope == this.calibrationSlope &&
          other.calibrationOffset == this.calibrationOffset &&
          other.notes == this.notes &&
          other.sampleCount == this.sampleCount &&
          other.isCompleted == this.isCompleted &&
          other.gaps == this.gaps &&
          other.visibleChannels == this.visibleChannels);
}

class SessionsCompanion extends UpdateCompanion<Session> {
  final Value<int> id;
  final Value<String> name;
  final Value<DateTime> createdAt;
  final Value<int> durationMs;
  final Value<int> sampleRate;
  final Value<int> channelCount;
  final Value<String> channelLabels;
  final Value<String> tares;
  final Value<double> peakForceRaw;
  final Value<int> peakForceChannel;
  final Value<double> calibrationSlope;
  final Value<int> calibrationOffset;
  final Value<String> notes;
  final Value<int> sampleCount;
  final Value<bool> isCompleted;
  final Value<String> gaps;
  final Value<String> visibleChannels;
  const SessionsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.sampleRate = const Value.absent(),
    this.channelCount = const Value.absent(),
    this.channelLabels = const Value.absent(),
    this.tares = const Value.absent(),
    this.peakForceRaw = const Value.absent(),
    this.peakForceChannel = const Value.absent(),
    this.calibrationSlope = const Value.absent(),
    this.calibrationOffset = const Value.absent(),
    this.notes = const Value.absent(),
    this.sampleCount = const Value.absent(),
    this.isCompleted = const Value.absent(),
    this.gaps = const Value.absent(),
    this.visibleChannels = const Value.absent(),
  });
  SessionsCompanion.insert({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    required DateTime createdAt,
    this.durationMs = const Value.absent(),
    this.sampleRate = const Value.absent(),
    this.channelCount = const Value.absent(),
    this.channelLabels = const Value.absent(),
    this.tares = const Value.absent(),
    this.peakForceRaw = const Value.absent(),
    this.peakForceChannel = const Value.absent(),
    this.calibrationSlope = const Value.absent(),
    this.calibrationOffset = const Value.absent(),
    this.notes = const Value.absent(),
    this.sampleCount = const Value.absent(),
    this.isCompleted = const Value.absent(),
    this.gaps = const Value.absent(),
    this.visibleChannels = const Value.absent(),
  }) : createdAt = Value(createdAt);
  static Insertable<Session> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<DateTime>? createdAt,
    Expression<int>? durationMs,
    Expression<int>? sampleRate,
    Expression<int>? channelCount,
    Expression<String>? channelLabels,
    Expression<String>? tares,
    Expression<double>? peakForceRaw,
    Expression<int>? peakForceChannel,
    Expression<double>? calibrationSlope,
    Expression<int>? calibrationOffset,
    Expression<String>? notes,
    Expression<int>? sampleCount,
    Expression<bool>? isCompleted,
    Expression<String>? gaps,
    Expression<String>? visibleChannels,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (sampleRate != null) 'sample_rate': sampleRate,
      if (channelCount != null) 'channel_count': channelCount,
      if (channelLabels != null) 'channel_labels': channelLabels,
      if (tares != null) 'tares': tares,
      if (peakForceRaw != null) 'peak_force_raw': peakForceRaw,
      if (peakForceChannel != null) 'peak_force_channel': peakForceChannel,
      if (calibrationSlope != null) 'calibration_slope': calibrationSlope,
      if (calibrationOffset != null) 'calibration_offset': calibrationOffset,
      if (notes != null) 'notes': notes,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (isCompleted != null) 'is_completed': isCompleted,
      if (gaps != null) 'gaps': gaps,
      if (visibleChannels != null) 'visible_channels': visibleChannels,
    });
  }

  SessionsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<DateTime>? createdAt,
    Value<int>? durationMs,
    Value<int>? sampleRate,
    Value<int>? channelCount,
    Value<String>? channelLabels,
    Value<String>? tares,
    Value<double>? peakForceRaw,
    Value<int>? peakForceChannel,
    Value<double>? calibrationSlope,
    Value<int>? calibrationOffset,
    Value<String>? notes,
    Value<int>? sampleCount,
    Value<bool>? isCompleted,
    Value<String>? gaps,
    Value<String>? visibleChannels,
  }) {
    return SessionsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      durationMs: durationMs ?? this.durationMs,
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      channelLabels: channelLabels ?? this.channelLabels,
      tares: tares ?? this.tares,
      peakForceRaw: peakForceRaw ?? this.peakForceRaw,
      peakForceChannel: peakForceChannel ?? this.peakForceChannel,
      calibrationSlope: calibrationSlope ?? this.calibrationSlope,
      calibrationOffset: calibrationOffset ?? this.calibrationOffset,
      notes: notes ?? this.notes,
      sampleCount: sampleCount ?? this.sampleCount,
      isCompleted: isCompleted ?? this.isCompleted,
      gaps: gaps ?? this.gaps,
      visibleChannels: visibleChannels ?? this.visibleChannels,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (sampleRate.present) {
      map['sample_rate'] = Variable<int>(sampleRate.value);
    }
    if (channelCount.present) {
      map['channel_count'] = Variable<int>(channelCount.value);
    }
    if (channelLabels.present) {
      map['channel_labels'] = Variable<String>(channelLabels.value);
    }
    if (tares.present) {
      map['tares'] = Variable<String>(tares.value);
    }
    if (peakForceRaw.present) {
      map['peak_force_raw'] = Variable<double>(peakForceRaw.value);
    }
    if (peakForceChannel.present) {
      map['peak_force_channel'] = Variable<int>(peakForceChannel.value);
    }
    if (calibrationSlope.present) {
      map['calibration_slope'] = Variable<double>(calibrationSlope.value);
    }
    if (calibrationOffset.present) {
      map['calibration_offset'] = Variable<int>(calibrationOffset.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (sampleCount.present) {
      map['sample_count'] = Variable<int>(sampleCount.value);
    }
    if (isCompleted.present) {
      map['is_completed'] = Variable<bool>(isCompleted.value);
    }
    if (gaps.present) {
      map['gaps'] = Variable<String>(gaps.value);
    }
    if (visibleChannels.present) {
      map['visible_channels'] = Variable<String>(visibleChannels.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('sampleRate: $sampleRate, ')
          ..write('channelCount: $channelCount, ')
          ..write('channelLabels: $channelLabels, ')
          ..write('tares: $tares, ')
          ..write('peakForceRaw: $peakForceRaw, ')
          ..write('peakForceChannel: $peakForceChannel, ')
          ..write('calibrationSlope: $calibrationSlope, ')
          ..write('calibrationOffset: $calibrationOffset, ')
          ..write('notes: $notes, ')
          ..write('sampleCount: $sampleCount, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('gaps: $gaps, ')
          ..write('visibleChannels: $visibleChannels')
          ..write(')'))
        .toString();
  }
}

class $SessionChunksTable extends SessionChunks
    with TableInfo<$SessionChunksTable, SessionChunk> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionChunksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chunkIndexMeta = const VerificationMeta(
    'chunkIndex',
  );
  @override
  late final GeneratedColumn<int> chunkIndex = GeneratedColumn<int>(
    'chunk_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [sessionId, chunkIndex, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'session_chunks';
  @override
  VerificationContext validateIntegrity(
    Insertable<SessionChunk> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('chunk_index')) {
      context.handle(
        _chunkIndexMeta,
        chunkIndex.isAcceptableOrUnknown(data['chunk_index']!, _chunkIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_chunkIndexMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sessionId, chunkIndex};
  @override
  SessionChunk map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SessionChunk(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      chunkIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chunk_index'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $SessionChunksTable createAlias(String alias) {
    return $SessionChunksTable(attachedDatabase, alias);
  }
}

class SessionChunk extends DataClass implements Insertable<SessionChunk> {
  final int sessionId;
  final int chunkIndex;
  final Uint8List data;
  const SessionChunk({
    required this.sessionId,
    required this.chunkIndex,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<int>(sessionId);
    map['chunk_index'] = Variable<int>(chunkIndex);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  SessionChunksCompanion toCompanion(bool nullToAbsent) {
    return SessionChunksCompanion(
      sessionId: Value(sessionId),
      chunkIndex: Value(chunkIndex),
      data: Value(data),
    );
  }

  factory SessionChunk.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SessionChunk(
      sessionId: serializer.fromJson<int>(json['sessionId']),
      chunkIndex: serializer.fromJson<int>(json['chunkIndex']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<int>(sessionId),
      'chunkIndex': serializer.toJson<int>(chunkIndex),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  SessionChunk copyWith({int? sessionId, int? chunkIndex, Uint8List? data}) =>
      SessionChunk(
        sessionId: sessionId ?? this.sessionId,
        chunkIndex: chunkIndex ?? this.chunkIndex,
        data: data ?? this.data,
      );
  SessionChunk copyWithCompanion(SessionChunksCompanion data) {
    return SessionChunk(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      chunkIndex: data.chunkIndex.present
          ? data.chunkIndex.value
          : this.chunkIndex,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SessionChunk(')
          ..write('sessionId: $sessionId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(sessionId, chunkIndex, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SessionChunk &&
          other.sessionId == this.sessionId &&
          other.chunkIndex == this.chunkIndex &&
          $driftBlobEquality.equals(other.data, this.data));
}

class SessionChunksCompanion extends UpdateCompanion<SessionChunk> {
  final Value<int> sessionId;
  final Value<int> chunkIndex;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const SessionChunksCompanion({
    this.sessionId = const Value.absent(),
    this.chunkIndex = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SessionChunksCompanion.insert({
    required int sessionId,
    required int chunkIndex,
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       chunkIndex = Value(chunkIndex),
       data = Value(data);
  static Insertable<SessionChunk> custom({
    Expression<int>? sessionId,
    Expression<int>? chunkIndex,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (chunkIndex != null) 'chunk_index': chunkIndex,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SessionChunksCompanion copyWith({
    Value<int>? sessionId,
    Value<int>? chunkIndex,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return SessionChunksCompanion(
      sessionId: sessionId ?? this.sessionId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (chunkIndex.present) {
      map['chunk_index'] = Variable<int>(chunkIndex.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionChunksCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SessionsTable sessions = $SessionsTable(this);
  late final $SessionChunksTable sessionChunks = $SessionChunksTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [sessions, sessionChunks];
}

typedef $$SessionsTableCreateCompanionBuilder =
    SessionsCompanion Function({
      Value<int> id,
      Value<String> name,
      required DateTime createdAt,
      Value<int> durationMs,
      Value<int> sampleRate,
      Value<int> channelCount,
      Value<String> channelLabels,
      Value<String> tares,
      Value<double> peakForceRaw,
      Value<int> peakForceChannel,
      Value<double> calibrationSlope,
      Value<int> calibrationOffset,
      Value<String> notes,
      Value<int> sampleCount,
      Value<bool> isCompleted,
      Value<String> gaps,
      Value<String> visibleChannels,
    });
typedef $$SessionsTableUpdateCompanionBuilder =
    SessionsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<DateTime> createdAt,
      Value<int> durationMs,
      Value<int> sampleRate,
      Value<int> channelCount,
      Value<String> channelLabels,
      Value<String> tares,
      Value<double> peakForceRaw,
      Value<int> peakForceChannel,
      Value<double> calibrationSlope,
      Value<int> calibrationOffset,
      Value<String> notes,
      Value<int> sampleCount,
      Value<bool> isCompleted,
      Value<String> gaps,
      Value<String> visibleChannels,
    });

class $$SessionsTableFilterComposer
    extends Composer<_$AppDatabase, $SessionsTable> {
  $$SessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sampleRate => $composableBuilder(
    column: $table.sampleRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get channelCount => $composableBuilder(
    column: $table.channelCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get channelLabels => $composableBuilder(
    column: $table.channelLabels,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tares => $composableBuilder(
    column: $table.tares,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get peakForceRaw => $composableBuilder(
    column: $table.peakForceRaw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get peakForceChannel => $composableBuilder(
    column: $table.peakForceChannel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get calibrationSlope => $composableBuilder(
    column: $table.calibrationSlope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get calibrationOffset => $composableBuilder(
    column: $table.calibrationOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gaps => $composableBuilder(
    column: $table.gaps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get visibleChannels => $composableBuilder(
    column: $table.visibleChannels,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $SessionsTable> {
  $$SessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sampleRate => $composableBuilder(
    column: $table.sampleRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get channelCount => $composableBuilder(
    column: $table.channelCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get channelLabels => $composableBuilder(
    column: $table.channelLabels,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tares => $composableBuilder(
    column: $table.tares,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get peakForceRaw => $composableBuilder(
    column: $table.peakForceRaw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get peakForceChannel => $composableBuilder(
    column: $table.peakForceChannel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get calibrationSlope => $composableBuilder(
    column: $table.calibrationSlope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get calibrationOffset => $composableBuilder(
    column: $table.calibrationOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gaps => $composableBuilder(
    column: $table.gaps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get visibleChannels => $composableBuilder(
    column: $table.visibleChannels,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SessionsTable> {
  $$SessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sampleRate => $composableBuilder(
    column: $table.sampleRate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get channelCount => $composableBuilder(
    column: $table.channelCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get channelLabels => $composableBuilder(
    column: $table.channelLabels,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tares =>
      $composableBuilder(column: $table.tares, builder: (column) => column);

  GeneratedColumn<double> get peakForceRaw => $composableBuilder(
    column: $table.peakForceRaw,
    builder: (column) => column,
  );

  GeneratedColumn<int> get peakForceChannel => $composableBuilder(
    column: $table.peakForceChannel,
    builder: (column) => column,
  );

  GeneratedColumn<double> get calibrationSlope => $composableBuilder(
    column: $table.calibrationSlope,
    builder: (column) => column,
  );

  GeneratedColumn<int> get calibrationOffset => $composableBuilder(
    column: $table.calibrationOffset,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => column,
  );

  GeneratedColumn<String> get gaps =>
      $composableBuilder(column: $table.gaps, builder: (column) => column);

  GeneratedColumn<String> get visibleChannels => $composableBuilder(
    column: $table.visibleChannels,
    builder: (column) => column,
  );
}

class $$SessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SessionsTable,
          Session,
          $$SessionsTableFilterComposer,
          $$SessionsTableOrderingComposer,
          $$SessionsTableAnnotationComposer,
          $$SessionsTableCreateCompanionBuilder,
          $$SessionsTableUpdateCompanionBuilder,
          (Session, BaseReferences<_$AppDatabase, $SessionsTable, Session>),
          Session,
          PrefetchHooks Function()
        > {
  $$SessionsTableTableManager(_$AppDatabase db, $SessionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<int> sampleRate = const Value.absent(),
                Value<int> channelCount = const Value.absent(),
                Value<String> channelLabels = const Value.absent(),
                Value<String> tares = const Value.absent(),
                Value<double> peakForceRaw = const Value.absent(),
                Value<int> peakForceChannel = const Value.absent(),
                Value<double> calibrationSlope = const Value.absent(),
                Value<int> calibrationOffset = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> sampleCount = const Value.absent(),
                Value<bool> isCompleted = const Value.absent(),
                Value<String> gaps = const Value.absent(),
                Value<String> visibleChannels = const Value.absent(),
              }) => SessionsCompanion(
                id: id,
                name: name,
                createdAt: createdAt,
                durationMs: durationMs,
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelLabels: channelLabels,
                tares: tares,
                peakForceRaw: peakForceRaw,
                peakForceChannel: peakForceChannel,
                calibrationSlope: calibrationSlope,
                calibrationOffset: calibrationOffset,
                notes: notes,
                sampleCount: sampleCount,
                isCompleted: isCompleted,
                gaps: gaps,
                visibleChannels: visibleChannels,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                required DateTime createdAt,
                Value<int> durationMs = const Value.absent(),
                Value<int> sampleRate = const Value.absent(),
                Value<int> channelCount = const Value.absent(),
                Value<String> channelLabels = const Value.absent(),
                Value<String> tares = const Value.absent(),
                Value<double> peakForceRaw = const Value.absent(),
                Value<int> peakForceChannel = const Value.absent(),
                Value<double> calibrationSlope = const Value.absent(),
                Value<int> calibrationOffset = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> sampleCount = const Value.absent(),
                Value<bool> isCompleted = const Value.absent(),
                Value<String> gaps = const Value.absent(),
                Value<String> visibleChannels = const Value.absent(),
              }) => SessionsCompanion.insert(
                id: id,
                name: name,
                createdAt: createdAt,
                durationMs: durationMs,
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelLabels: channelLabels,
                tares: tares,
                peakForceRaw: peakForceRaw,
                peakForceChannel: peakForceChannel,
                calibrationSlope: calibrationSlope,
                calibrationOffset: calibrationOffset,
                notes: notes,
                sampleCount: sampleCount,
                isCompleted: isCompleted,
                gaps: gaps,
                visibleChannels: visibleChannels,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SessionsTable,
      Session,
      $$SessionsTableFilterComposer,
      $$SessionsTableOrderingComposer,
      $$SessionsTableAnnotationComposer,
      $$SessionsTableCreateCompanionBuilder,
      $$SessionsTableUpdateCompanionBuilder,
      (Session, BaseReferences<_$AppDatabase, $SessionsTable, Session>),
      Session,
      PrefetchHooks Function()
    >;
typedef $$SessionChunksTableCreateCompanionBuilder =
    SessionChunksCompanion Function({
      required int sessionId,
      required int chunkIndex,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$SessionChunksTableUpdateCompanionBuilder =
    SessionChunksCompanion Function({
      Value<int> sessionId,
      Value<int> chunkIndex,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$SessionChunksTableFilterComposer
    extends Composer<_$AppDatabase, $SessionChunksTable> {
  $$SessionChunksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SessionChunksTableOrderingComposer
    extends Composer<_$AppDatabase, $SessionChunksTable> {
  $$SessionChunksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SessionChunksTableAnnotationComposer
    extends Composer<_$AppDatabase, $SessionChunksTable> {
  $$SessionChunksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$SessionChunksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SessionChunksTable,
          SessionChunk,
          $$SessionChunksTableFilterComposer,
          $$SessionChunksTableOrderingComposer,
          $$SessionChunksTableAnnotationComposer,
          $$SessionChunksTableCreateCompanionBuilder,
          $$SessionChunksTableUpdateCompanionBuilder,
          (
            SessionChunk,
            BaseReferences<_$AppDatabase, $SessionChunksTable, SessionChunk>,
          ),
          SessionChunk,
          PrefetchHooks Function()
        > {
  $$SessionChunksTableTableManager(_$AppDatabase db, $SessionChunksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SessionChunksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SessionChunksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SessionChunksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> sessionId = const Value.absent(),
                Value<int> chunkIndex = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SessionChunksCompanion(
                sessionId: sessionId,
                chunkIndex: chunkIndex,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int sessionId,
                required int chunkIndex,
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => SessionChunksCompanion.insert(
                sessionId: sessionId,
                chunkIndex: chunkIndex,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SessionChunksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SessionChunksTable,
      SessionChunk,
      $$SessionChunksTableFilterComposer,
      $$SessionChunksTableOrderingComposer,
      $$SessionChunksTableAnnotationComposer,
      $$SessionChunksTableCreateCompanionBuilder,
      $$SessionChunksTableUpdateCompanionBuilder,
      (
        SessionChunk,
        BaseReferences<_$AppDatabase, $SessionChunksTable, SessionChunk>,
      ),
      SessionChunk,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db, _db.sessions);
  $$SessionChunksTableTableManager get sessionChunks =>
      $$SessionChunksTableTableManager(_db, _db.sessionChunks);
}
