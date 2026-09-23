import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Interface-board calibration: the analog-chain constants, the factory ladder
// calibration, and the flash document's board half. A board has a zero offset,
// a cell a zero balance; load cells live in `load_cell.dart`.
// ---------------------------------------------------------------------------

/// ADC counts per polarity (24-bit bipolar: 2^23 per side).
const int adcCountsPerPolarity = 1 << 23;

/// The signed 24-bit rails; values outside are reserved by the session codec
/// as its gap sentinel.
const int adcMaxValue = adcCountsPerPolarity - 1;
const int adcMinValue = -adcCountsPerPolarity;

// ---------------------------------------------------------------------------
// Board constants (analog chain), resolved from the device
// ---------------------------------------------------------------------------

/// The analog-chain constants converting one channel's raw counts, resolved
/// from the device at connect time. A board without this data shows raw counts
/// only (see [UnprovisionedBoardCalibration]).
class ChannelNominals {
  const ChannelNominals({
    required this.adcFsrV,
    required this.afeGain,
    required this.pgaGain,
    required this.excitationV,
  });

  /// ADC full-scale reference voltage (flash `adc_fsr`).
  final double adcFsrV;

  /// Analog front-end gain ahead of the ADC (flash `afe_gain`).
  final double afeGain;

  /// The ADC's PGA gain for this channel (GAIN register readback).
  final double pgaGain;

  /// Excitation voltage (flash `exc`).
  final double excitationV;

  /// ADC counts per mV at the load cell output.
  double get countsPerMvAtCellOutput =>
      adcCountsPerPolarity * afeGain * pgaGain / (adcFsrV * 1000.0);

  /// ADC counts per mV/V of load cell output.
  double get countsPerMvV => countsPerMvAtCellOutput * excitationV;

  Map<String, dynamic> toJson() => {
    'fsr': adcFsrV,
    'afe': afeGain,
    'pga': pgaGain,
    'exc': excitationV,
  };

  /// Strict inverse of [toJson]: every field must be present, finite and
  /// positive, else [FormatException].
  factory ChannelNominals.fromJson(Map<String, dynamic> json) {
    double pos(Object? v, String key) {
      final d = v is num ? v.toDouble() : double.nan;
      if (!d.isFinite || d <= 0) {
        throw FormatException('channel nominals: bad $key: $v');
      }
      return d;
    }

    return ChannelNominals(
      adcFsrV: pos(json['fsr'], 'fsr'),
      afeGain: pos(json['afe'], 'afe'),
      pgaGain: pos(json['pga'], 'pga'),
      excitationV: pos(json['exc'], 'exc'),
    );
  }
}

/// Board-level analog constants: shared chain values, per-channel PGA gains,
/// and the provenance tags on the flash values.
class BoardNominals {
  BoardNominals({
    required this.adcFsrV,
    required this.afeGain,
    required this.excitationV,
    required this.pgaGains,
    this.provenance = const {},
  }) : assert(pgaGains.length == kAdcChannelCount);

  final double adcFsrV;
  final double afeGain;
  final double excitationV;

  /// Per-channel PGA gains from the ADC's GAIN register readback.
  final List<double> pgaGains;

  /// Provenance tag per flash key (`exc` -> `nominal`, ...); absent when
  /// the value carried no tag.
  final Map<String, String> provenance;

  ChannelNominals forChannel(int i) => ChannelNominals(
    adcFsrV: adcFsrV,
    afeGain: afeGain,
    pgaGain: pgaGains[i],
    excitationV: excitationV,
  );
}

/// Flash keys carrying the board constants (Factory namespace).
const List<String> boardConstantKeys = ['adc_fsr', 'exc', 'afe_gain'];

/// The exact per-channel calibration keys the schema owns.
final Set<String> channelCalibrationKeys = Set.unmodifiable({
  for (int i = 0; i < kAdcChannelCount; ++i) ...['ch$i.r', 'ch$i.raw'],
});

/// The exact calibration-group keys the schema owns: the marker
/// (`cal.date`), the provenance metadata, and the per-channel entries.
final Set<String> calGroupKeys = Set.unmodifiable({
  'cal.date',
  'cal.board',
  'cal.tool',
  'cal.origin',
  'cal.temp',
  'cal.adc',
  ...channelCalibrationKeys,
});

/// Resolve the board constants from a flash document's key=value map and the
/// ADC's PGA readback. Null when the flash holds none of the constant keys (an
/// unprovisioned board, which streams raw counts only). Throws
/// [FormatException] on a partial or malformed set; [DeviceFlash.fromKvs]
/// turns that into an [InvalidBoardCalibration], so bad provisioning still
/// streams raw counts rather than failing the connection.
BoardNominals? resolveBoardConstants(
  Map<String, String> kv, {
  required List<double> pgaGains,
}) {
  if (!boardConstantKeys.any(kv.containsKey)) return null;
  final missing = [
    for (final k in boardConstantKeys)
      if (!kv.containsKey(k)) k,
  ];
  if (missing.isNotEmpty) {
    throw FormatException('board constants: missing ${missing.join(', ')}');
  }
  final values = <String, double>{};
  final provenance = <String, String>{};
  for (final key in boardConstantKeys) {
    // Values may carry a provenance tag: "4.53,nominal".
    final parts = kv[key]!.split(',');
    final value = double.tryParse(parts.first.trim());
    if (value == null || !value.isFinite || value <= 0) {
      throw FormatException('board constants: bad $key: "${kv[key]}"');
    }
    values[key] = value;
    if (parts.length > 1) {
      provenance[key] = parts.sublist(1).join(',').trim();
    }
  }
  return BoardNominals(
    adcFsrV: values['adc_fsr']!,
    excitationV: values['exc']!,
    afeGain: values['afe_gain']!,
    pgaGains: pgaGains,
    provenance: provenance,
  );
}

// ---------------------------------------------------------------------------
// Calibration ladder
// ---------------------------------------------------------------------------

/// Resistors per calibration ladder: top 10k, four 10R in series, bottom 10k,
/// in signal order from EXC+ to GND. Taps sit between them: t1 after the top
/// 10k, t5 before the bottom 10k.
const int kLadderResistorCount = 6;

/// Differential configurations measured at factory calibration, in storage
/// order: (t1,t5), (t2,t4), (t3,t3), (t4,t2), (t5,t1). The middle one is a
/// dead short — a true zero independent of resistor values.
const int kCalPointCount = 5;

/// Storage-order indices of the cal points by signal role: the outermost
/// points bracket a load cell's full-scale range, the middle one is the
/// dead-short zero.
const int kCalIdxPosFs = 0;
const int kCalIdxPosMid = 1;
const int kCalIdxZero = 2;
const int kCalIdxNegMid = 3;
const int kCalIdxNegFs = 4;

/// Display labels for the [kCalPointCount] configs — the tap pairs wired at
/// factory calibration, in storage order.
const List<String> calConfigLabels = [
  '(t1, t5)',
  '(t2, t4)',
  '(t3, t3)',
  '(t4, t2)',
  '(t5, t1)',
];

/// Differential setpoints (mV/V of excitation) for the [kCalPointCount]
/// configs, computed from the ladder's resistor values alone — the ladder is
/// ratiometric, so the excitation cancels and only ratios matter. Tap order
/// follows [kCalPointCount] storage order.
List<double> ladderSetpointsMvV(List<double> resistors) {
  assert(resistors.length == kLadderResistorCount);
  // Resistance below each tap (toward GND).
  final below = List<double>.filled(kCalPointCount, 0);
  double acc = 0;
  for (int i = kLadderResistorCount - 1; i >= 1; --i) {
    acc += resistors[i];
    below[i - 1] = acc;
  }
  final total = acc + resistors[0];
  return [
    for (int k = 0; k < kCalPointCount; ++k)
      1000.0 *
          (below[k] - below[kCalPointCount - 1 - k]) /
          total, // (t_k, t_5-k)
  ];
}

// ---------------------------------------------------------------------------
// Board calibration (per channel, from device flash)
// ---------------------------------------------------------------------------

/// Board-side calibration data of one ADC channel, as a sealed two-state:
/// [CalibratedChannelBoard] carries factory data (a piecewise-linear map
/// through the five (raw, setpoint) points), [NominalChannelBoard] the nominal
/// chain alone. Both convert; "no board data at all" is a null
/// `ChannelCalibration.board`, where only raw counts convert.
sealed class ChannelBoardCalibration {
  const ChannelBoardCalibration._();

  /// The channel's resolved analog chain.
  ChannelNominals get nominals;

  /// Whether the channel has a calibration group. Board-level calibration is
  /// all-or-nothing (see [BoardCalibration.fromKv]).
  bool get isCalibrated;

  /// The excitation anchor for the mV unit. The calibration is ratiometric, so
  /// only mV depends on it; a distinct role from
  /// [ChannelNominals.excitationV], even though it resolves to the same value.
  double get displayExcitationV => nominals.excitationV;

  /// End-point sensitivity in counts per mV/V: the chord through the two
  /// outermost cal points on [CalibratedChannelBoard], the nominal chain's
  /// value on [NominalChannelBoard].
  double get sensitivityCountsPerMvV;

  /// Map an absolute raw ADC reading (offset included) to mV/V of excitation.
  double mvVFromRaw(double raw);

  /// Inverse of [mvVFromRaw].
  double rawFromMvV(double mvV);

  /// Joint validity check for one channel's factory data, shared by the
  /// flash and session-snapshot parsers: [kLadderResistorCount] positive
  /// resistors (a zero or negative value gives nonsense setpoints or a NaN
  /// ladder total) and [kCalPointCount] finite readings inside the ADC's
  /// bipolar range, at least 1000 counts apart (a duplicate or near-zero gap
  /// is corrupt flash; exact duplicates would divide by zero during
  /// interpolation). Both null = "no factory data" is NOT valid here;
  /// callers check presence before calling.
  static bool channelDataIsValid(
    List<double> resistors,
    List<double> readings,
  ) {
    assert(resistors.length == kLadderResistorCount);
    assert(readings.length == kCalPointCount);
    for (final v in resistors) {
      // A non-finite or non-positive resistor produces nonsense setpoints
      // (or a zero ladder total → NaN).
      if (!v.isFinite || v <= 0) return false;
    }
    final sorted = [...readings]..sort();
    for (final v in sorted) {
      // 'NaN'/'Infinity' parse fine with double.tryParse — reject them and
      // anything beyond the ADC's bipolar range: neither came from hardware.
      if (!v.isFinite ||
          v >= adcCountsPerPolarity ||
          v < -adcCountsPerPolarity) {
        return false;
      }
    }
    for (int i = 1; i < sorted.length; ++i) {
      if (sorted[i] - sorted[i - 1] < 1000) return false;
    }
    return true;
  }

  /// Session-snapshot serialization. The resolved nominals ride along so
  /// replay never re-resolves anything.
  Map<String, dynamic> toJson();

  /// Strict inverse of [toJson]: nominals are required (a session with no
  /// board data stores a null board), factory data optional, but
  /// present-but-malformed throws [FormatException]. Replay never substitutes
  /// guessed values.
  factory ChannelBoardCalibration.fromJson(Map<String, dynamic> json) {
    List<double>? numList(Object? v, int count, String key) {
      if (v == null) return null;
      if (v is! List || v.length != count) {
        throw FormatException('board calibration: bad $key list');
      }
      return [
        for (final e in v)
          e is num
              ? e.toDouble()
              : throw FormatException('board calibration: bad $key entry'),
      ];
    }

    final n = json['n'];
    if (n is! Map) {
      throw const FormatException('board calibration: missing nominals');
    }
    final nominals = ChannelNominals.fromJson(Map<String, dynamic>.from(n));

    final resistors = numList(json['r'], kLadderResistorCount, 'r');
    final readings = numList(json['raw'], kCalPointCount, 'raw');
    if (resistors == null && readings == null) {
      return NominalChannelBoard(nominals);
    }
    // One half of the pair, or values failing the joint validity check,
    // can only be a damaged snapshot — never a partial instrument.
    if (resistors == null ||
        readings == null ||
        !channelDataIsValid(resistors, readings)) {
      throw const FormatException('board calibration: invalid channel data');
    }
    return CalibratedChannelBoard(
      resistors: resistors,
      readings: readings,
      nominals: nominals,
    );
  }
}

/// One channel's factory calibration: the characterized ladder resistors,
/// the readings per config, and the resolved nominal chain — the only
/// variant holding measured data; every measured member is non-null by
/// construction.
class CalibratedChannelBoard extends ChannelBoardCalibration {
  CalibratedChannelBoard({
    required List<double> resistors,
    required List<double> readings,
    required this.nominals,
  }) : resistors = List.unmodifiable(resistors),
       readings = List.unmodifiable(readings),
       super._() {
    // Sort the five points ascending by raw reading for interpolation.
    final order = [for (int k = 0; k < kCalPointCount; ++k) k]
      ..sort((a, b) => this.readings[a].compareTo(this.readings[b]));
    final sp = setpoints;
    _sortedRaw = [for (final k in order) this.readings[k]];
    _sortedSetpoints = [for (final k in order) sp[k]];
  }

  /// Characterized ladder resistors ([kLadderResistorCount]).
  final List<double> resistors;

  /// Factory-averaged raw counts per config, in [kCalPointCount] storage
  /// order.
  final List<double> readings;

  @override
  final ChannelNominals nominals;

  @override
  bool get isCalibrated => true;

  /// Setpoints (mV/V) per config, derived from [resistors]. Cached: pure
  /// function of the immutable [resistors], and per-sample conversion paths
  /// reach it via [sensitivityCountsPerMvV].
  late final List<double> setpoints = ladderSetpointsMvV(resistors);

  late final List<double> _sortedRaw;
  late final List<double> _sortedSetpoints;

  /// Map an absolute raw ADC reading to mV/V of excitation via the
  /// piecewise map. Out-of-range readings extend the outermost segment.
  @override
  double mvVFromRaw(double raw) {
    final xs = _sortedRaw;
    final ys = _sortedSetpoints;
    // Right endpoint of the segment containing raw, clamped to the outer
    // segments: below/above the cal range extrapolates along them.
    var i = 1;
    while (i < xs.length - 1 && raw > xs[i]) {
      ++i;
    }
    return ys[i - 1] +
        (raw - xs[i - 1]) * (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1]);
  }

  /// Inverse of [mvVFromRaw]: the segment lookup runs on the setpoint axis
  /// (monotone across a valid channel's span); out-of-range extends the outer
  /// segment.
  @override
  double rawFromMvV(double mvV) {
    final xs = _sortedRaw;
    final ys = _sortedSetpoints;
    var i = 1;
    while (i < ys.length - 1 && mvV > ys[i]) {
      ++i;
    }
    return xs[i - 1] +
        (mvV - ys[i - 1]) * (xs[i] - xs[i - 1]) / (ys[i] - ys[i - 1]);
  }

  // -- Diagnostics ----------------------------------------------------------

  /// Dead-short (t3,t3) reading: the AFE+ADC input offset, no cell in the
  /// loop.
  double get offsetCounts => readings[kCalIdxZero];

  /// The chord through the two outermost cal points. Cached.
  @override
  late final double sensitivityCountsPerMvV =
      (readings[kCalIdxPosFs] - readings[kCalIdxNegFs]) /
      (setpoints[kCalIdxPosFs] - setpoints[kCalIdxNegFs]);

  /// Board zero offset in µV/V: the dead-short reading expressed through the
  /// measured sensitivity, so the nominal chain never enters. Not the load
  /// cell's certificate "zero balance".
  double get zeroOffsetUvV => offsetCounts / sensitivityCountsPerMvV * 1000.0;

  /// Gain error vs the nominal chain (1.0 = exactly nominal): the only
  /// diagnostic that references the nominal chain, folding excitation, AFE
  /// gain, ADC reference and ladder tolerances into one factor whose split is
  /// unknowable.
  double get sensitivityVsNominal =>
      sensitivityCountsPerMvV / nominals.countsPerMvV;

  /// As-found error per cal point in µV/V (storage order): the reading through
  /// the nominal chain minus the setpoint. Offset, gain and curvature all
  /// appear; no entry is pinned to zero.
  List<double> get measuredErrorsUvV {
    final sp = setpoints;
    final s = nominals.countsPerMvV;
    return [
      for (int k = 0; k < kCalPointCount; ++k)
        (readings[k] / s - sp[k]) * 1000.0,
    ];
  }

  /// End-point nonlinearity per cal point in µV/V (storage order): deviation
  /// from the ±FS chord via the measured sensitivity. The ±FS entries are 0 by
  /// construction; positive = the uncorrected device read high.
  List<double> get deviationsUvV {
    final sp = setpoints;
    final s = sensitivityCountsPerMvV;
    final rPos = readings[kCalIdxPosFs], rNeg = readings[kCalIdxNegFs];
    final spPos = sp[kCalIdxPosFs], spNeg = sp[kCalIdxNegFs];
    return [
      for (int k = 0; k < kCalPointCount; ++k)
        (readings[k] -
                (rNeg + (rPos - rNeg) * (sp[k] - spNeg) / (spPos - spNeg))) /
            s *
            1000.0,
    ];
  }

  /// The headline linearity figure: max |deviation| over the cal points,
  /// in µV/V.
  double get maxDeviationUvV {
    var m = 0.0;
    for (final v in deviationsUvV) {
      if (v.abs() > m) m = v.abs();
    }
    return m;
  }

  @override
  Map<String, dynamic> toJson() => {
    'r': resistors,
    'raw': readings,
    'n': nominals.toJson(),
  };
}

/// A channel with resolved nominals but no factory data: the nominal chain is
/// the map.
class NominalChannelBoard extends ChannelBoardCalibration {
  const NominalChannelBoard(this.nominals) : super._();

  @override
  final ChannelNominals nominals;

  @override
  bool get isCalibrated => false;

  @override
  double get sensitivityCountsPerMvV => nominals.countsPerMvV;

  @override
  double mvVFromRaw(double raw) => raw / nominals.countsPerMvV;

  @override
  double rawFromMvV(double mvV) => mvV * nominals.countsPerMvV;

  @override
  Map<String, dynamic> toJson() => {'n': nominals.toJson()};
}

// ---------------------------------------------------------------------------
// The calibration group (all channels + provenance, one document)
// ---------------------------------------------------------------------------

/// One complete calibration group: every channel's ladder data plus the
/// `cal.*` provenance metadata.
///
/// Its presence marker is [date] (`cal.date`), written last, so a crash
/// mid-write leaves data keys without a date. [parseCalGroup] reads that as "no
/// group"; [BoardCalibration.fromKv] treats orphaned keys as corrupt flash — the
/// tool always writes the date, so its absence means an interrupted
/// recalibration, which must not be ignored while the user expects the new
/// calibration to be in effect.
class CalGroup {
  CalGroup({
    required this.date,
    this.boardId,
    this.tool,
    this.origin,
    this.tempsC,
    this.adcGains,
    required this.channelData,
  }) : assert(channelData.length == kAdcChannelCount);

  /// Calibration date string as written in flash (`cal.date`).
  final String date;

  /// Calibration board firmware id (`cal.board`), if any.
  final String? boardId;

  /// Calibration host script version (`cal.tool`), if any.
  final String? tool;

  /// Calibration origin tag (`cal.origin`: `factory`, or a field operator's
  /// tag), if any.
  final String? origin;

  /// Temperatures at calibration in °C (`cal.temp`): DUT board, cal board.
  final ({double dut, double calBoard})? tempsC;

  /// Per-channel ADC PGA gains at calibration time (`cal.adc`), if recorded.
  final List<double>? adcGains;

  /// One ladder/readings pair per ADC channel; the two validate together.
  final List<({List<double> resistors, List<double> readings})> channelData;
}

/// Parse the calibration keys [key] as a comma-separated list of exactly
/// [count] finite numbers. Null when the key is absent. Throws
/// [FormatException] on anything else.
List<double>? _parseNumberList(String? value, int count, String key) {
  if (value == null) return null;
  final parts = value.split(',');
  final parsed = [
    for (final part in parts)
      part.isEmpty ? null : double.tryParse(part.trim()),
  ];
  if (parsed.length != count || parsed.any((v) => v == null || !v.isFinite)) {
    throw FormatException('calibration: bad $key: "$value"');
  }
  return [for (final v in parsed) v!];
}

/// Parse one calibration group out of a key/value map. Null when the map holds
/// no `cal.date` (the presence marker; orphaned group keys are the caller's
/// policy). Throws [FormatException] on a present-but-invalid group:
/// calibration is all-or-nothing, so every channel's ladder/readings must be
/// present and jointly valid.
CalGroup? parseCalGroup(Map<String, String> kv) {
  final date = kv['cal.date'];
  if (date == null) return null;
  final channelData = <({List<double> resistors, List<double> readings})?>[];
  var sawAbsent = false;
  var sawPresent = false;
  for (int i = 0; i < kAdcChannelCount; ++i) {
    final hasEntries = kv.containsKey('ch$i.r') || kv.containsKey('ch$i.raw');
    if (!hasEntries) {
      channelData.add(null);
      sawAbsent = true;
      continue;
    }
    final resistors = _parseNumberList(
      kv['ch$i.r'],
      kLadderResistorCount,
      'ch$i.r',
    );
    final readings = _parseNumberList(
      kv['ch$i.raw'],
      kCalPointCount,
      'ch$i.raw',
    );
    if (resistors == null ||
        readings == null ||
        !ChannelBoardCalibration.channelDataIsValid(resistors, readings)) {
      throw FormatException('calibration: invalid channel data (ch$i)');
    }
    channelData.add((resistors: resistors, readings: readings));
    sawPresent = true;
  }
  if (sawAbsent || !sawPresent) {
    throw const FormatException('calibration: only some channels calibrated');
  }
  final temps = _parseNumberList(kv['cal.temp'], 2, 'cal.temp');
  return CalGroup(
    date: date,
    boardId: kv['cal.board'],
    tool: kv['cal.tool'],
    origin: kv['cal.origin'],
    tempsC: temps == null ? null : (dut: temps[0], calBoard: temps[1]),
    adcGains: _parseNumberList(kv['cal.adc'], kAdcChannelCount, 'cal.adc'),
    channelData: [for (final d in channelData) d!],
  );
}

/// The board half of the device flash document, sealed by provisioning:
/// [ProvisionedBoardCalibration] (constants resolved),
/// [UnprovisionedBoardCalibration] (no board data — raw counts only), or
/// [InvalidBoardCalibration] (data the app refuses to adopt; carries the
/// reason).
///
/// A failed READ (transport) fails the connection upstream, so no board object
/// represents "couldn't read".
sealed class BoardCalibration {
  const BoardCalibration._();

  /// Parse the board half of a flash document from the FACTORY key/value map.
  /// [pgaGains] completes the board constants (see [resolveBoardConstants]).
  ///
  /// Throws [FormatException] on present-but-invalid board data: partial
  /// constants, orphaned calibration keys, or a rejected cal group. Absent data
  /// is legal (unprovisioned → raw counts; constants without a cal group →
  /// nominal channels). Unknown keys are ignored. [DeviceFlash.fromKvs] turns
  /// this into an [InvalidBoardCalibration].
  factory BoardCalibration.fromKv(
    Map<String, String> kv, {
    required List<double> pgaGains,
  }) {
    final nominals = resolveBoardConstants(kv, pgaGains: pgaGains);
    if (nominals == null) {
      // Calibration keys without the constant chain are a bad-provisioning
      // fragment, not "unprovisioned".
      if (kv.keys.any(calGroupKeys.contains)) {
        throw const FormatException(
          'board data: calibration keys without the constant chain '
          '(run provision first)',
        );
      }
      return const UnprovisionedBoardCalibration();
    }

    final group = parseCalGroup(kv);
    if (group == null && kv.keys.any(calGroupKeys.contains)) {
      // No date marker, so every calibration key must be absent outright.
      throw const FormatException(
        'board calibration: calibration keys without the cal.date marker',
      );
    }
    return ProvisionedBoardCalibration(nominals: nominals, calGroup: group);
  }
}

/// A board with resolved constants; no cal group means every channel uses the
/// nominal chain.
class ProvisionedBoardCalibration extends BoardCalibration {
  ProvisionedBoardCalibration({required this.nominals, this.calGroup})
    : channels = [
        for (int i = 0; i < kAdcChannelCount; ++i)
          switch (calGroup?.channelData[i]) {
            null => NominalChannelBoard(nominals.forChannel(i)),
            final data => CalibratedChannelBoard(
              resistors: data.resistors,
              readings: data.readings,
              nominals: nominals.forChannel(i),
            ),
          },
      ],
      super._();

  /// The resolved board constants (see [resolveBoardConstants]).
  final BoardNominals nominals;

  /// Null when flash holds constants but no calibration.
  final CalGroup? calGroup;

  /// One map per ADC channel, derived from [nominals] and [calGroup].
  final List<ChannelBoardCalibration> channels;

  /// True when the runtime PGA config differs from the calibration's — a
  /// stale-calibration guard. Null when the calibration recorded no gains.
  bool? get adcConfigDrifted {
    final atCal = calGroup?.adcGains;
    if (atCal == null) return null;
    final current = nominals.pgaGains;
    if (atCal.length != current.length) return true;
    for (int i = 0; i < atCal.length; ++i) {
      if (atCal[i] != current[i]) return true;
    }
    return false;
  }

  /// Whether the board holds a calibration group (see [CalGroup]).
  bool get isCalibrated => calGroup != null;
}

/// A board with no board data in flash: a new or factory-reset unit. Streams
/// raw counts only.
class UnprovisionedBoardCalibration extends BoardCalibration {
  const UnprovisionedBoardCalibration() : super._();
}

/// A board whose flash data the app refused to adopt (see
/// [BoardCalibration.fromKv]); streams raw counts like
/// [UnprovisionedBoardCalibration]. [detail] names the offending key.
class InvalidBoardCalibration extends BoardCalibration {
  const InvalidBoardCalibration(this.detail) : super._();

  /// The parser's reason, e.g. `board constants: bad adc_fsr: "soon"`.
  final String detail;
}
