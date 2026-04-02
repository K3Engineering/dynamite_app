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
  static const VerificationMeta _dataFilePathMeta = const VerificationMeta(
    'dataFilePath',
  );
  @override
  late final GeneratedColumn<String> dataFilePath = GeneratedColumn<String>(
    'data_file_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    createdAt,
    durationMs,
    sampleRate,
    channelCount,
    channelLabels,
    peakForceRaw,
    peakForceChannel,
    calibrationSlope,
    calibrationOffset,
    notes,
    dataFilePath,
    sampleCount,
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
    if (data.containsKey('data_file_path')) {
      context.handle(
        _dataFilePathMeta,
        dataFilePath.isAcceptableOrUnknown(
          data['data_file_path']!,
          _dataFilePathMeta,
        ),
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
      dataFilePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_file_path'],
      ),
      sampleCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sample_count'],
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
  final double peakForceRaw;
  final int peakForceChannel;
  final double calibrationSlope;
  final int calibrationOffset;
  final String notes;
  final String? dataFilePath;
  final int sampleCount;
  const Session({
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
    this.dataFilePath,
    required this.sampleCount,
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
    map['peak_force_raw'] = Variable<double>(peakForceRaw);
    map['peak_force_channel'] = Variable<int>(peakForceChannel);
    map['calibration_slope'] = Variable<double>(calibrationSlope);
    map['calibration_offset'] = Variable<int>(calibrationOffset);
    map['notes'] = Variable<String>(notes);
    if (!nullToAbsent || dataFilePath != null) {
      map['data_file_path'] = Variable<String>(dataFilePath);
    }
    map['sample_count'] = Variable<int>(sampleCount);
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
      peakForceRaw: Value(peakForceRaw),
      peakForceChannel: Value(peakForceChannel),
      calibrationSlope: Value(calibrationSlope),
      calibrationOffset: Value(calibrationOffset),
      notes: Value(notes),
      dataFilePath: dataFilePath == null && nullToAbsent
          ? const Value.absent()
          : Value(dataFilePath),
      sampleCount: Value(sampleCount),
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
      peakForceRaw: serializer.fromJson<double>(json['peakForceRaw']),
      peakForceChannel: serializer.fromJson<int>(json['peakForceChannel']),
      calibrationSlope: serializer.fromJson<double>(json['calibrationSlope']),
      calibrationOffset: serializer.fromJson<int>(json['calibrationOffset']),
      notes: serializer.fromJson<String>(json['notes']),
      dataFilePath: serializer.fromJson<String?>(json['dataFilePath']),
      sampleCount: serializer.fromJson<int>(json['sampleCount']),
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
      'peakForceRaw': serializer.toJson<double>(peakForceRaw),
      'peakForceChannel': serializer.toJson<int>(peakForceChannel),
      'calibrationSlope': serializer.toJson<double>(calibrationSlope),
      'calibrationOffset': serializer.toJson<int>(calibrationOffset),
      'notes': serializer.toJson<String>(notes),
      'dataFilePath': serializer.toJson<String?>(dataFilePath),
      'sampleCount': serializer.toJson<int>(sampleCount),
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
    double? peakForceRaw,
    int? peakForceChannel,
    double? calibrationSlope,
    int? calibrationOffset,
    String? notes,
    Value<String?> dataFilePath = const Value.absent(),
    int? sampleCount,
  }) => Session(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    durationMs: durationMs ?? this.durationMs,
    sampleRate: sampleRate ?? this.sampleRate,
    channelCount: channelCount ?? this.channelCount,
    channelLabels: channelLabels ?? this.channelLabels,
    peakForceRaw: peakForceRaw ?? this.peakForceRaw,
    peakForceChannel: peakForceChannel ?? this.peakForceChannel,
    calibrationSlope: calibrationSlope ?? this.calibrationSlope,
    calibrationOffset: calibrationOffset ?? this.calibrationOffset,
    notes: notes ?? this.notes,
    dataFilePath: dataFilePath.present ? dataFilePath.value : this.dataFilePath,
    sampleCount: sampleCount ?? this.sampleCount,
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
      dataFilePath: data.dataFilePath.present
          ? data.dataFilePath.value
          : this.dataFilePath,
      sampleCount: data.sampleCount.present
          ? data.sampleCount.value
          : this.sampleCount,
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
          ..write('peakForceRaw: $peakForceRaw, ')
          ..write('peakForceChannel: $peakForceChannel, ')
          ..write('calibrationSlope: $calibrationSlope, ')
          ..write('calibrationOffset: $calibrationOffset, ')
          ..write('notes: $notes, ')
          ..write('dataFilePath: $dataFilePath, ')
          ..write('sampleCount: $sampleCount')
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
    peakForceRaw,
    peakForceChannel,
    calibrationSlope,
    calibrationOffset,
    notes,
    dataFilePath,
    sampleCount,
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
          other.peakForceRaw == this.peakForceRaw &&
          other.peakForceChannel == this.peakForceChannel &&
          other.calibrationSlope == this.calibrationSlope &&
          other.calibrationOffset == this.calibrationOffset &&
          other.notes == this.notes &&
          other.dataFilePath == this.dataFilePath &&
          other.sampleCount == this.sampleCount);
}

class SessionsCompanion extends UpdateCompanion<Session> {
  final Value<int> id;
  final Value<String> name;
  final Value<DateTime> createdAt;
  final Value<int> durationMs;
  final Value<int> sampleRate;
  final Value<int> channelCount;
  final Value<String> channelLabels;
  final Value<double> peakForceRaw;
  final Value<int> peakForceChannel;
  final Value<double> calibrationSlope;
  final Value<int> calibrationOffset;
  final Value<String> notes;
  final Value<String?> dataFilePath;
  final Value<int> sampleCount;
  const SessionsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.sampleRate = const Value.absent(),
    this.channelCount = const Value.absent(),
    this.channelLabels = const Value.absent(),
    this.peakForceRaw = const Value.absent(),
    this.peakForceChannel = const Value.absent(),
    this.calibrationSlope = const Value.absent(),
    this.calibrationOffset = const Value.absent(),
    this.notes = const Value.absent(),
    this.dataFilePath = const Value.absent(),
    this.sampleCount = const Value.absent(),
  });
  SessionsCompanion.insert({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    required DateTime createdAt,
    this.durationMs = const Value.absent(),
    this.sampleRate = const Value.absent(),
    this.channelCount = const Value.absent(),
    this.channelLabels = const Value.absent(),
    this.peakForceRaw = const Value.absent(),
    this.peakForceChannel = const Value.absent(),
    this.calibrationSlope = const Value.absent(),
    this.calibrationOffset = const Value.absent(),
    this.notes = const Value.absent(),
    this.dataFilePath = const Value.absent(),
    this.sampleCount = const Value.absent(),
  }) : createdAt = Value(createdAt);
  static Insertable<Session> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<DateTime>? createdAt,
    Expression<int>? durationMs,
    Expression<int>? sampleRate,
    Expression<int>? channelCount,
    Expression<String>? channelLabels,
    Expression<double>? peakForceRaw,
    Expression<int>? peakForceChannel,
    Expression<double>? calibrationSlope,
    Expression<int>? calibrationOffset,
    Expression<String>? notes,
    Expression<String>? dataFilePath,
    Expression<int>? sampleCount,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (sampleRate != null) 'sample_rate': sampleRate,
      if (channelCount != null) 'channel_count': channelCount,
      if (channelLabels != null) 'channel_labels': channelLabels,
      if (peakForceRaw != null) 'peak_force_raw': peakForceRaw,
      if (peakForceChannel != null) 'peak_force_channel': peakForceChannel,
      if (calibrationSlope != null) 'calibration_slope': calibrationSlope,
      if (calibrationOffset != null) 'calibration_offset': calibrationOffset,
      if (notes != null) 'notes': notes,
      if (dataFilePath != null) 'data_file_path': dataFilePath,
      if (sampleCount != null) 'sample_count': sampleCount,
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
    Value<double>? peakForceRaw,
    Value<int>? peakForceChannel,
    Value<double>? calibrationSlope,
    Value<int>? calibrationOffset,
    Value<String>? notes,
    Value<String?>? dataFilePath,
    Value<int>? sampleCount,
  }) {
    return SessionsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      durationMs: durationMs ?? this.durationMs,
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      channelLabels: channelLabels ?? this.channelLabels,
      peakForceRaw: peakForceRaw ?? this.peakForceRaw,
      peakForceChannel: peakForceChannel ?? this.peakForceChannel,
      calibrationSlope: calibrationSlope ?? this.calibrationSlope,
      calibrationOffset: calibrationOffset ?? this.calibrationOffset,
      notes: notes ?? this.notes,
      dataFilePath: dataFilePath ?? this.dataFilePath,
      sampleCount: sampleCount ?? this.sampleCount,
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
    if (dataFilePath.present) {
      map['data_file_path'] = Variable<String>(dataFilePath.value);
    }
    if (sampleCount.present) {
      map['sample_count'] = Variable<int>(sampleCount.value);
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
          ..write('peakForceRaw: $peakForceRaw, ')
          ..write('peakForceChannel: $peakForceChannel, ')
          ..write('calibrationSlope: $calibrationSlope, ')
          ..write('calibrationOffset: $calibrationOffset, ')
          ..write('notes: $notes, ')
          ..write('dataFilePath: $dataFilePath, ')
          ..write('sampleCount: $sampleCount')
          ..write(')'))
        .toString();
  }
}

class $SessionBlobsTable extends SessionBlobs
    with TableInfo<$SessionBlobsTable, SessionBlob> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionBlobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
  List<GeneratedColumn> get $columns => [sessionId, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'session_blobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SessionBlob> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
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
  Set<GeneratedColumn> get $primaryKey => {sessionId};
  @override
  SessionBlob map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SessionBlob(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $SessionBlobsTable createAlias(String alias) {
    return $SessionBlobsTable(attachedDatabase, alias);
  }
}

class SessionBlob extends DataClass implements Insertable<SessionBlob> {
  final int sessionId;
  final Uint8List data;
  const SessionBlob({required this.sessionId, required this.data});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<int>(sessionId);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  SessionBlobsCompanion toCompanion(bool nullToAbsent) {
    return SessionBlobsCompanion(
      sessionId: Value(sessionId),
      data: Value(data),
    );
  }

  factory SessionBlob.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SessionBlob(
      sessionId: serializer.fromJson<int>(json['sessionId']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<int>(sessionId),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  SessionBlob copyWith({int? sessionId, Uint8List? data}) => SessionBlob(
    sessionId: sessionId ?? this.sessionId,
    data: data ?? this.data,
  );
  SessionBlob copyWithCompanion(SessionBlobsCompanion data) {
    return SessionBlob(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SessionBlob(')
          ..write('sessionId: $sessionId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sessionId, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SessionBlob &&
          other.sessionId == this.sessionId &&
          $driftBlobEquality.equals(other.data, this.data));
}

class SessionBlobsCompanion extends UpdateCompanion<SessionBlob> {
  final Value<int> sessionId;
  final Value<Uint8List> data;
  const SessionBlobsCompanion({
    this.sessionId = const Value.absent(),
    this.data = const Value.absent(),
  });
  SessionBlobsCompanion.insert({
    this.sessionId = const Value.absent(),
    required Uint8List data,
  }) : data = Value(data);
  static Insertable<SessionBlob> custom({
    Expression<int>? sessionId,
    Expression<Uint8List>? data,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (data != null) 'data': data,
    });
  }

  SessionBlobsCompanion copyWith({
    Value<int>? sessionId,
    Value<Uint8List>? data,
  }) {
    return SessionBlobsCompanion(
      sessionId: sessionId ?? this.sessionId,
      data: data ?? this.data,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionBlobsCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SessionsTable sessions = $SessionsTable(this);
  late final $SessionBlobsTable sessionBlobs = $SessionBlobsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [sessions, sessionBlobs];
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
      Value<double> peakForceRaw,
      Value<int> peakForceChannel,
      Value<double> calibrationSlope,
      Value<int> calibrationOffset,
      Value<String> notes,
      Value<String?> dataFilePath,
      Value<int> sampleCount,
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
      Value<double> peakForceRaw,
      Value<int> peakForceChannel,
      Value<double> calibrationSlope,
      Value<int> calibrationOffset,
      Value<String> notes,
      Value<String?> dataFilePath,
      Value<int> sampleCount,
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

  ColumnFilters<String> get dataFilePath => $composableBuilder(
    column: $table.dataFilePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
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

  ColumnOrderings<String> get dataFilePath => $composableBuilder(
    column: $table.dataFilePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
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

  GeneratedColumn<String> get dataFilePath => $composableBuilder(
    column: $table.dataFilePath,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sampleCount => $composableBuilder(
    column: $table.sampleCount,
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
                Value<double> peakForceRaw = const Value.absent(),
                Value<int> peakForceChannel = const Value.absent(),
                Value<double> calibrationSlope = const Value.absent(),
                Value<int> calibrationOffset = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> dataFilePath = const Value.absent(),
                Value<int> sampleCount = const Value.absent(),
              }) => SessionsCompanion(
                id: id,
                name: name,
                createdAt: createdAt,
                durationMs: durationMs,
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelLabels: channelLabels,
                peakForceRaw: peakForceRaw,
                peakForceChannel: peakForceChannel,
                calibrationSlope: calibrationSlope,
                calibrationOffset: calibrationOffset,
                notes: notes,
                dataFilePath: dataFilePath,
                sampleCount: sampleCount,
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
                Value<double> peakForceRaw = const Value.absent(),
                Value<int> peakForceChannel = const Value.absent(),
                Value<double> calibrationSlope = const Value.absent(),
                Value<int> calibrationOffset = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> dataFilePath = const Value.absent(),
                Value<int> sampleCount = const Value.absent(),
              }) => SessionsCompanion.insert(
                id: id,
                name: name,
                createdAt: createdAt,
                durationMs: durationMs,
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelLabels: channelLabels,
                peakForceRaw: peakForceRaw,
                peakForceChannel: peakForceChannel,
                calibrationSlope: calibrationSlope,
                calibrationOffset: calibrationOffset,
                notes: notes,
                dataFilePath: dataFilePath,
                sampleCount: sampleCount,
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
typedef $$SessionBlobsTableCreateCompanionBuilder =
    SessionBlobsCompanion Function({
      Value<int> sessionId,
      required Uint8List data,
    });
typedef $$SessionBlobsTableUpdateCompanionBuilder =
    SessionBlobsCompanion Function({
      Value<int> sessionId,
      Value<Uint8List> data,
    });

class $$SessionBlobsTableFilterComposer
    extends Composer<_$AppDatabase, $SessionBlobsTable> {
  $$SessionBlobsTableFilterComposer({
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

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SessionBlobsTableOrderingComposer
    extends Composer<_$AppDatabase, $SessionBlobsTable> {
  $$SessionBlobsTableOrderingComposer({
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

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SessionBlobsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SessionBlobsTable> {
  $$SessionBlobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$SessionBlobsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SessionBlobsTable,
          SessionBlob,
          $$SessionBlobsTableFilterComposer,
          $$SessionBlobsTableOrderingComposer,
          $$SessionBlobsTableAnnotationComposer,
          $$SessionBlobsTableCreateCompanionBuilder,
          $$SessionBlobsTableUpdateCompanionBuilder,
          (
            SessionBlob,
            BaseReferences<_$AppDatabase, $SessionBlobsTable, SessionBlob>,
          ),
          SessionBlob,
          PrefetchHooks Function()
        > {
  $$SessionBlobsTableTableManager(_$AppDatabase db, $SessionBlobsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SessionBlobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SessionBlobsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SessionBlobsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> sessionId = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
              }) => SessionBlobsCompanion(sessionId: sessionId, data: data),
          createCompanionCallback:
              ({
                Value<int> sessionId = const Value.absent(),
                required Uint8List data,
              }) => SessionBlobsCompanion.insert(
                sessionId: sessionId,
                data: data,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SessionBlobsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SessionBlobsTable,
      SessionBlob,
      $$SessionBlobsTableFilterComposer,
      $$SessionBlobsTableOrderingComposer,
      $$SessionBlobsTableAnnotationComposer,
      $$SessionBlobsTableCreateCompanionBuilder,
      $$SessionBlobsTableUpdateCompanionBuilder,
      (
        SessionBlob,
        BaseReferences<_$AppDatabase, $SessionBlobsTable, SessionBlob>,
      ),
      SessionBlob,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db, _db.sessions);
  $$SessionBlobsTableTableManager get sessionBlobs =>
      $$SessionBlobsTableTableManager(_db, _db.sessionBlobs);
}
