import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Interface-board calibration: the analog-chain constants, the factory
// ladder calibration, and the flash document's board half. Everything here
// is a property of the BOARD (ADC, AFE, excitation, cal ladder) — load cell
// profiles and rig slots live in `load_cell.dart`, and the vocabulary stays
// separate: a board has a zero OFFSET, a cell has a zero BALANCE.
// ---------------------------------------------------------------------------

/// ADC counts per polarity (24-bit bipolar: 2^23 per side). Protocol-level:
/// the sample format, not a conversion nominal.
const int adcCountsPerPolarity = 1 << 23;

// ---------------------------------------------------------------------------
// Board constants (analog chain), resolved from the device
// ---------------------------------------------------------------------------

/// The analog-chain constants converting one channel's raw counts: ADC
/// full-scale reference, AFE gain, the ADC's PGA gain, excitation voltage.
/// Resolved from the device at connect time (flash keys + ADC register
/// readback) — the app carries NO compiled defaults: a board without this
/// data shows raw counts only (see [BoardDataStatus]).
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
  /// positive, else [FormatException] — a partial chain is never guessed.
  /// Session-snapshot callers catch at their boundary (damage policy lives
  /// there, not here).
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

/// The board-data verdict driving the raw-only degradation and its message.
enum BoardDataStatus {
  /// Constants resolved; electrical (and force) units convert.
  ok,

  /// No board constants in flash: the unit was never provisioned.
  unprovisioned,

  /// Some constants present but missing/malformed: a bad provisioning.
  invalid,

  /// The constants could not be read at all (transport failure).
  unreadable,
}

/// User-facing phrases for the raw-only notice ("… — raw counts only").
extension BoardDataStatusText on BoardDataStatus {
  String notice(String detail) => switch (this) {
    BoardDataStatus.ok => '',
    BoardDataStatus.unprovisioned => 'no board data — unit not provisioned',
    BoardDataStatus.invalid =>
      'board data invalid${detail.isEmpty ? '' : ' ($detail)'}',
    BoardDataStatus.unreadable =>
      'board data not read${detail.isEmpty ? '' : ' ($detail)'}',
  };
}

/// Board-level analog constants: the shared chain values, the per-channel
/// PGA gains, and the provenance tags carried by the flash values
/// (e.g. `"4.53,nominal"`).
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

/// The outcome of [resolveBoardConstants]: the chain on
/// [BoardDataStatus.ok], else a status + human-readable detail for the
/// raw-only notice.
class BoardConstantsResolution {
  const BoardConstantsResolution.ok(this.nominals)
    : status = BoardDataStatus.ok,
      detail = '';
  const BoardConstantsResolution.failure(this.status, [this.detail = ''])
    : nominals = null;

  final BoardNominals? nominals;
  final BoardDataStatus status;
  final String detail;
}

/// Flash keys carrying the board constants (Factory namespace).
const List<String> boardConstantKeys = ['adc_fsr', 'exc', 'afe_gain'];

/// Resolve the board constants from a flash document's key=value map and the
/// ADC's PGA readback ([pgaGains] — always present: an unreadable ADC config
/// fails the connection upstream). All-or-nothing: every required value must
/// be present and positive, else the whole chain degrades (the app never
/// guesses a partial chain).
BoardConstantsResolution resolveBoardConstants(
  Map<String, String> kv, {
  required List<double> pgaGains,
}) {
  if (!boardConstantKeys.any(kv.containsKey)) {
    return const BoardConstantsResolution.failure(
      BoardDataStatus.unprovisioned,
    );
  }
  final missing = [
    for (final k in boardConstantKeys)
      if (!kv.containsKey(k)) k,
  ];
  if (missing.isNotEmpty) {
    return BoardConstantsResolution.failure(
      BoardDataStatus.invalid,
      'missing ${missing.join(', ')}',
    );
  }
  final values = <String, double>{};
  final provenance = <String, String>{};
  for (final key in boardConstantKeys) {
    // Values may carry a provenance tag: "4.53,nominal".
    final parts = kv[key]!.split(',');
    final value = double.tryParse(parts.first.trim());
    if (value == null || value <= 0) {
      return BoardConstantsResolution.failure(
        BoardDataStatus.invalid,
        'bad $key: "${kv[key]}"',
      );
    }
    values[key] = value;
    if (parts.length > 1) {
      provenance[key] = parts.sublist(1).join(',').trim();
    }
  }
  return BoardConstantsResolution.ok(
    BoardNominals(
      adcFsrV: values['adc_fsr']!,
      excitationV: values['exc']!,
      afeGain: values['afe_gain']!,
      pgaGains: pgaGains,
      provenance: provenance,
    ),
  );
}

// ---------------------------------------------------------------------------
// Calibration ladder
// ---------------------------------------------------------------------------

/// Resistors per calibration ladder: [top 10k, four 10R, bottom 10k], in
/// signal order from EXC+ to GND. Taps sit between them: t1 after the top
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

/// Board-side calibration data of one ADC channel, as a sealed three-state:
///
/// - [CalibratedChannelBoard]: the characterized ladder resistors and the
///   raw readings the device produced in each of the [kCalPointCount]
///   differential configs, plus the resolved nominal chain. Conversion is a
///   piecewise-linear map through the five (raw, setpoint) points — it
///   absorbs ADC offset, the combined AFE/ADC/excitation gain, and ADC
///   nonlinearity between the cal points.
/// - [NominalChannelBoard]: no factory data; the resolved nominal chain is
///   the map.
/// - [RawOnlyChannelBoard]: the board constants never resolved (see
///   [BoardDataStatus]) — the channel shows raw counts only; every
///   conversion reports unavailable, guarded at the unit layer.
///
/// The ladder and the readings are one datum (never a
/// characterized-rereading-over-nominal-ladder remix), and readings never
/// exist without resolved nominals (the parse paths only consult cal keys
/// once the board constants resolved); the measured members exist only on
/// [CalibratedChannelBoard].
sealed class ChannelBoardCalibration {
  const ChannelBoardCalibration._();

  /// The channel's resolved analog chain; null only on
  /// [RawOnlyChannelBoard] — every conversion then reports unavailable
  /// (raw counts only), guarded at the unit layer.
  ChannelNominals? get nominals;

  /// Whether the channel has factory calibration. Board-level calibration
  /// is all-or-nothing: every channel is calibrated, or none is (see
  /// BoardCalibration.fromKv).
  bool get isFactoryCalibrated;

  /// The excitation anchor expressing the ratiometric map as mV. This value
  /// is the mV unit's entire uncertainty — the calibration is ratiometric,
  /// so the calibrated units never touch it. Deliberately not
  /// [ChannelNominals.excitationV]'s name: the nominal chain constant and
  /// the mV anchor are two roles that happen to resolve to the same number.
  /// Null on a raw-only channel (conversion reports unavailable anyway).
  double? get displayExcitationV => nominals?.excitationV;

  /// End-point sensitivity in counts per mV/V: measured on
  /// [CalibratedChannelBoard] (the chord through the two outermost cal
  /// points, which bracket a load cell's full-scale range — the slope of
  /// the conversion map where one number must stand in for it), the nominal
  /// chain's value on [NominalChannelBoard]. Null with no resolved board
  /// constants — nothing converts then.
  double? get sensitivityCountsPerMvV;

  /// Map an absolute raw ADC reading to mV/V of excitation. Readings are
  /// absolute (offset included): net values come from subtracting the map at
  /// the tare point — see `ChannelConverter.netMap`.
  double mvVFromRaw(double raw);

  /// Inverse of [mvVFromRaw]: the raw reading mapping to [mvV] (manual
  /// tare entry converts a typed display value back to counts).
  double rawFromMvV(double mvV);

  /// Joint validity check for one channel's factory data, shared by the
  /// flash and session-snapshot parsers: the ladder ([kLadderResistorCount]
  /// positive values — a real ladder resistor is ~10k/~10 ohms, and a zero
  /// or negative value produces nonsense setpoints or a NaN ladder total)
  /// and the readings ([kCalPointCount] finite values inside the ADC's
  /// bipolar range, at least 1000 counts apart — a real ladder spread is
  /// millions of counts, so a sub-thousand gap can only be corrupt flash,
  /// and exact duplicates would divide by zero during interpolation). Both
  /// null = "no factory data" is NOT valid here; callers check presence
  /// before calling.
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

  /// Session-snapshot serialization (recorded sessions carry the
  /// calibration they were taken with, so playback converts identically
  /// later). The resolved nominals ride along: replay must never re-resolve
  /// anything.
  Map<String, dynamic> toJson();

  /// Strict inverse of [toJson], honoring the variant structure: absent
  /// optional keys are legal (no factory data, or no resolved nominals),
  /// but present-but-malformed data throws [FormatException] — one half of
  /// the ladder/readings pair without the other, readings without resolved
  /// nominals, or values failing [channelDataIsValid]. Replay never
  /// substitutes guessed values; the caller decides the damage policy
  /// (the session catalog marks the session damaged).
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
    final nominals = n == null
        ? null
        : ChannelNominals.fromJson(
            n is Map
                ? Map<String, dynamic>.from(n)
                : throw const FormatException('board calibration: bad n'),
          );

    final resistors = numList(json['r'], kLadderResistorCount, 'r');
    final readings = numList(json['raw'], kCalPointCount, 'raw');
    if (resistors == null && readings == null) {
      return nominals == null
          ? const RawOnlyChannelBoard()
          : NominalChannelBoard(nominals);
    }
    // One half of the pair, or readings without a nominal chain, can only
    // be a damaged snapshot — never a partial instrument.
    if (resistors == null ||
        readings == null ||
        nominals == null ||
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
  bool get isFactoryCalibrated => true;

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

  /// Inverse of [mvVFromRaw]: the segment lookup run against the setpoint
  /// axis (the map is monotone across a valid channel's span); out-of-range
  /// values extend the outermost segment, mirroring [mvVFromRaw].
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

  /// Board zero offset in counts: the dead-short (t3,t3) reading measures
  /// the AFE+ADC input offset directly (no cell in the loop).
  double get offsetCounts => readings[kCalIdxZero];

  /// The measured end-point sensitivity: the slope of the chord through the
  /// two outermost cal points. Cached (see [setpoints]).
  @override
  late final double sensitivityCountsPerMvV =
      (readings[kCalIdxPosFs] - readings[kCalIdxNegFs]) /
      (setpoints[kCalIdxPosFs] - setpoints[kCalIdxNegFs]);

  /// Board zero offset in µV/V: the dead-short (t3,t3) reading expressed
  /// through the measured sensitivity — measured counts ÷ measured
  /// counts-per-mV/V, so the nominal chain (FSR, AFE gain, excitation) never
  /// enters. This is the interface board's OWN input offset (AFE + ADC, no
  /// cell in the loop) — NOT the load-cell certificate's "zero balance",
  /// which is a property of the cell.
  ///
  /// The measured-error table's zero row ([measuredErrorsUvV]) expresses
  /// the same offset through the nominal chain instead; the two differ by
  /// the gain factor — far below the calibration's uncertainty.
  double get zeroOffsetUvV => offsetCounts / sensitivityCountsPerMvV * 1000.0;

  /// Gain error vs the nominal chain (1.0 = exactly nominal): the measured
  /// end-point sensitivity relative to the nominal counts-per-mV/V. It
  /// folds excitation, AFE gain, ADC reference and ladder tolerances into
  /// one factor — the split is unknowable by design. The one diagnostic
  /// that references the nominal chain.
  double get sensitivityVsNominal =>
      sensitivityCountsPerMvV / nominals.countsPerMvV;

  /// Measured error per cal point in µV/V, in [kCalPointCount] storage
  /// order: the reading converted through the *nominal* chain minus the
  /// ladder setpoint — the as-found error, what an uncorrected reading
  /// would show. Offset, gain error and curvature all appear; the ±FS
  /// entries are NOT zero (unlike [deviationsUvV], nothing here is pinned
  /// by construction).
  List<double> get measuredErrorsUvV {
    final sp = setpoints;
    final s = nominals.countsPerMvV;
    return [
      for (int k = 0; k < kCalPointCount; ++k)
        (readings[k] / s - sp[k]) * 1000.0,
    ];
  }

  /// End-point nonlinearity per cal point in µV/V, in [kCalPointCount]
  /// storage order: deviation from the end-point line (the chord through
  /// the ±FS points), via the measured sensitivity — what the calibration
  /// corrects beyond gain and offset. The ±FS entries are 0 by
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

/// One channel with resolved board constants but no factory data: the
/// nominal chain alone is the conversion map — no offset, gain, or
/// nonlinearity correction.
class NominalChannelBoard extends ChannelBoardCalibration {
  const NominalChannelBoard(this.nominals) : super._();

  @override
  final ChannelNominals nominals;

  @override
  bool get isFactoryCalibrated => false;

  @override
  double get sensitivityCountsPerMvV => nominals.countsPerMvV;

  @override
  double mvVFromRaw(double raw) => raw / nominals.countsPerMvV;

  @override
  double rawFromMvV(double mvV) => mvV * nominals.countsPerMvV;

  @override
  Map<String, dynamic> toJson() => {'n': nominals.toJson()};
}

/// One channel with no resolved board constants ([BoardDataStatus] says
/// why): nothing converts but raw counts. The mV/V maps throw — the unit
/// layer reports unavailable instead of calling them, so a call here is a
/// usage error.
class RawOnlyChannelBoard extends ChannelBoardCalibration {
  const RawOnlyChannelBoard() : super._();

  @override
  ChannelNominals? get nominals => null;

  @override
  bool get isFactoryCalibrated => false;

  @override
  double? get sensitivityCountsPerMvV => null;

  @override
  double mvVFromRaw(double raw) =>
      throw StateError('raw-only channel: no board map to convert through');

  @override
  double rawFromMvV(double mvV) =>
      throw StateError('raw-only channel: no board map to invert through');

  @override
  Map<String, dynamic> toJson() => const {};
}

/// Board calibration of the whole device: one [ChannelBoardCalibration] per
/// ADC channel, the resolved board constants ([nominals] + the verdict that
/// produced them), plus optional factory metadata.
class BoardCalibration {
  BoardCalibration({
    required this.channels,
    this.factoryDate,
    this.calBoardId,
    this.calTool,
    this.calOrigin,
    this.calTempsC,
    this.calAdcGains,
    this.nominals,
    BoardDataStatus? constantsStatus,
    this.constantsDetail = '',
    this.calDataInvalid = false,
  }) : assert(channels.length == kAdcChannelCount),
       assert(
         channels.every((c) => c.isFactoryCalibrated) ||
             channels.every((c) => !c.isFactoryCalibrated),
         'calibration is uniform across channels — a mixed board is '
         'invalid flash, rejected at parse (see fromKv)',
       ),
       constantsStatus =
           constantsStatus ??
           (nominals != null ? BoardDataStatus.ok : BoardDataStatus.unreadable);

  final List<ChannelBoardCalibration> channels;

  /// Flash held calibration data the app refused to adopt: a channel's
  /// entries were present but malformed, or only some channels carried
  /// calibration. Such a board runs on the nominal chain like an
  /// uncalibrated one — this flag is the only remaining trace (one warning
  /// in the UI; the app does not diagnose what exactly is broken in flash).
  final bool calDataInvalid;

  /// Factory calibration date string as written in flash (`cal.date`), if any.
  final String? factoryDate;

  /// Calibration board firmware id (`cal.board`), if any.
  final String? calBoardId;

  /// Calibration host script version (`cal.tool`), if any.
  final String? calTool;

  /// Calibration origin tag (`cal.origin`: `factory`, or a field operator's
  /// tag), if any.
  final String? calOrigin;

  /// Temperatures at calibration in °C (`cal.temp`): DUT board, cal board.
  final ({double dut, double calBoard})? calTempsC;

  /// Per-channel ADC PGA gains at calibration time (`cal.adc`), if recorded.
  final List<double>? calAdcGains;

  /// The resolved board constants; null exactly when [constantsStatus] is
  /// not [BoardDataStatus.ok].
  final BoardNominals? nominals;

  /// The board-data verdict: whether [nominals] resolved, and why not.
  /// Drives the raw-only notice in the live UI and the unit availability
  /// behind the Settings picker's disabled segments.
  final BoardDataStatus constantsStatus;

  /// Human-readable reason when [constantsStatus] is not ok
  /// (e.g. "missing afe_gain").
  final String constantsDetail;

  /// Whether the runtime PGA config differs from the one the calibration was
  /// taken at — a stale-calibration guard (PGA gains are the only ADC config
  /// the runtime readback exposes). Null when either side is unknown.
  bool? get adcConfigDrifted {
    final atCal = calAdcGains;
    final current = nominals?.pgaGains;
    if (atCal == null || current == null) return null;
    if (atCal.length != current.length) return true;
    for (int i = 0; i < atCal.length; ++i) {
      if (atCal[i] != current[i]) return true;
    }
    return false;
  }

  /// Whether the board has factory calibration. Calibration is all-or-
  /// nothing per board (see [fromKv]): every channel is calibrated, or none
  /// is — a mixed board is never representable here.
  bool get isFactoryCalibrated => channels.every((c) => c.isFactoryCalibrated);

  /// Parse the board-calibration keys of a `key=value` flash document.
  /// Slot (`lcN.*`) and other unknown keys are ignored. Never throws — see
  /// [DeviceFlash.parse].
  factory BoardCalibration.parse(
    String text, {
    required List<double> pgaGains,
  }) => BoardCalibration.fromKv(parseFlashKv(text), pgaGains: pgaGains);

  /// Build from an already-split key=value map (see [parseFlashKv]).
  /// [pgaGains] is the ADC's GAIN-register readback (always present — see
  /// [resolveBoardConstants]) — it resolves the board constants whose
  /// verdict the result carries.
  ///
  /// Calibration is all-or-nothing at two levels. Channel: a channel's
  /// ladder resistors and readings validate together or drop together —
  /// never a characterized-readings-over-nominal-ladder remix. Board: every
  /// channel must carry valid data or the whole board reads as uncalibrated
  /// (a factory always calibrates all channels in one document; partial or
  /// malformed data is invalid flash, not a mixed instrument), with
  /// [calDataInvalid] set as the only trace. Calibration keys are only
  /// consulted once the board constants resolved — factory readings without
  /// a nominal chain convert nothing, so they parse as absent.
  factory BoardCalibration.fromKv(
    Map<String, String> kv, {
    required List<double> pgaGains,
  }) {
    List<double>? parseList(String? value, int count) {
      if (value == null) return null;
      final parts = value.split(',').map((s) => double.tryParse(s.trim()));
      if (parts.length != count || parts.any((v) => v == null)) return null;
      return [for (final v in parts) v!];
    }

    /// `cal.temp` is a 2-list: (DUT board, cal board) °C.
    ({double dut, double calBoard})? parseTemps(String? value) {
      final pair = parseList(value, 2);
      return pair == null ? null : (dut: pair[0], calBoard: pair[1]);
    }

    final constants = resolveBoardConstants(kv, pgaGains: pgaGains);
    final nominals = constants.nominals;

    // Content-validated calibration per channel, but only once the board
    // constants resolved (readings never exist without nominals).
    final calData = <({List<double> resistors, List<double> readings})?>[];
    var sawAbsent = false;
    var sawPresent = false;
    var calDataInvalid = false;
    if (nominals != null) {
      for (int i = 0; i < kAdcChannelCount; ++i) {
        final resistors = parseList(kv['ch$i.r'], kLadderResistorCount);
        final readings = parseList(kv['ch$i.raw'], kCalPointCount);
        final valid =
            resistors != null &&
            readings != null &&
            ChannelBoardCalibration.channelDataIsValid(resistors, readings);
        if (valid) {
          calData.add((resistors: resistors, readings: readings));
          sawPresent = true;
        } else {
          calData.add(null);
          if (kv['ch$i.r'] != null || kv['ch$i.raw'] != null) {
            sawPresent = true;
            calDataInvalid = true;
          } else {
            sawAbsent = true;
          }
        }
      }
    }
    // Partial flash (some channels calibrated, others absent entirely) is
    // invalid data too, not a mixed instrument.
    if (sawPresent && sawAbsent) calDataInvalid = true;
    final adoptCal = sawPresent && !calDataInvalid;

    return BoardCalibration(
      channels: [
        for (int i = 0; i < kAdcChannelCount; ++i)
          switch ((nominals, adoptCal ? calData[i] : null)) {
            (null, _) => const RawOnlyChannelBoard(),
            (final n?, null) => NominalChannelBoard(n.forChannel(i)),
            (final n?, final data!) => CalibratedChannelBoard(
              resistors: data.resistors,
              readings: data.readings,
              nominals: n.forChannel(i),
            ),
          },
      ],
      factoryDate: kv['cal.date'],
      calBoardId: kv['cal.board'],
      calTool: kv['cal.tool'],
      calOrigin: kv['cal.origin'],
      calTempsC: parseTemps(kv['cal.temp']),
      calAdcGains: parseList(kv['cal.adc'], kAdcChannelCount),
      nominals: nominals,
      constantsStatus: constants.status,
      constantsDetail: constants.detail,
      calDataInvalid: calDataInvalid,
    );
  }
}

/// The board-level calibration facts a recorded session freezes next to its
/// per-channel snapshot. [ChannelBoardCalibration.toJson] already carries the
/// operative numbers (r/raw/n); this block carries what those numbers WERE —
/// which calibration produced them (the `cal.*` provenance document) and
/// under what board state (the constants verdict, [BoardCalibration.calDataInvalid]) —
/// so a session recorded on a board with corrupt calibration flash reads
/// differently from one recorded on a genuinely uncalibrated board.
class SessionBoardMeta {
  const SessionBoardMeta({
    this.factoryDate,
    this.calBoardId,
    this.calTool,
    this.calOrigin,
    this.calTempsC,
    this.calAdcGains,
    required this.calDataInvalid,
    required this.constantsStatus,
    required this.constantsDetail,
    required this.provenance,
  });

  /// Snapshot of a live [BoardCalibration]'s board-level state.
  factory SessionBoardMeta.fromBoard(BoardCalibration board) =>
      SessionBoardMeta(
        factoryDate: board.factoryDate,
        calBoardId: board.calBoardId,
        calTool: board.calTool,
        calOrigin: board.calOrigin,
        calTempsC: board.calTempsC,
        calAdcGains: board.calAdcGains,
        calDataInvalid: board.calDataInvalid,
        constantsStatus: board.constantsStatus,
        constantsDetail: board.constantsDetail,
        provenance: board.nominals?.provenance ?? const {},
      );

  /// See [BoardCalibration.factoryDate].
  final String? factoryDate;

  /// See [BoardCalibration.calBoardId].
  final String? calBoardId;

  /// See [BoardCalibration.calTool].
  final String? calTool;

  /// See [BoardCalibration.calOrigin].
  final String? calOrigin;

  /// See [BoardCalibration.calTempsC].
  final ({double dut, double calBoard})? calTempsC;

  /// See [BoardCalibration.calAdcGains].
  final List<double>? calAdcGains;

  /// See [BoardCalibration.calDataInvalid].
  final bool calDataInvalid;

  /// See [BoardCalibration.constantsStatus].
  final BoardDataStatus constantsStatus;

  /// See [BoardCalibration.constantsDetail].
  final String constantsDetail;

  /// The flash-value provenance tags (`adc_fsr` -> `nominal`, ...); see
  /// [BoardNominals.provenance]. Empty when the constants never resolved.
  final Map<String, String> provenance;

  Map<String, dynamic> toJson() {
    final temps = calTempsC;
    return {
      'cal_date': ?factoryDate,
      'cal_board': ?calBoardId,
      'cal_tool': ?calTool,
      'cal_origin': ?calOrigin,
      'cal_temp': ?(temps == null ? null : [temps.dut, temps.calBoard]),
      'cal_adc': ?calAdcGains,
      'cal_data_invalid': calDataInvalid,
      'constants_status': constantsStatus.name,
      'constants_detail': constantsDetail,
      'provenance': provenance,
    };
  }

  /// Strict inverse of [toJson]: absent optional keys are legal (`null`
  /// flash fields stay null), but present-but-malformed data throws
  /// [FormatException] — the caller decides the damage policy (the session
  /// catalog marks the session damaged). Unknown keys are ignored.
  factory SessionBoardMeta.fromJson(Map<String, dynamic> json) {
    String? str(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String || v.isEmpty) {
        throw FormatException('board meta: bad $key: $v');
      }
      return v;
    }

    List<double>? numList(String key, int count) {
      final v = json[key];
      if (v == null) return null;
      if (v is! List || v.length != count) {
        throw FormatException('board meta: bad $key list');
      }
      return [
        for (final e in v)
          e is num && e.toDouble().isFinite
              ? e.toDouble()
              : throw FormatException('board meta: bad $key entry'),
      ];
    }

    final statusName = json['constants_status'];
    final status = statusName is String
        ? BoardDataStatus.values.asNameMap()[statusName]
        : null;
    if (status == null) {
      throw FormatException('board meta: bad constants_status: $statusName');
    }
    final detail = json['constants_detail'];
    if (detail is! String) {
      throw FormatException('board meta: bad constants_detail: $detail');
    }
    final invalid = json['cal_data_invalid'];
    if (invalid is! bool) {
      throw FormatException('board meta: bad cal_data_invalid: $invalid');
    }
    final prov = json['provenance'];
    if (prov is! Map || prov.values.any((v) => v is! String)) {
      throw const FormatException('board meta: bad provenance');
    }
    final temps = numList('cal_temp', 2);
    return SessionBoardMeta(
      factoryDate: str('cal_date'),
      calBoardId: str('cal_board'),
      calTool: str('cal_tool'),
      calOrigin: str('cal_origin'),
      calTempsC: temps == null ? null : (dut: temps[0], calBoard: temps[1]),
      calAdcGains: numList('cal_adc', kAdcChannelCount),
      calDataInvalid: invalid,
      constantsStatus: status,
      constantsDetail: detail,
      provenance: {
        for (final MapEntry(key: k, value: v) in prov.entries)
          k as String: v as String,
      },
    );
  }
}

/// Split a `key=value` flash document into a map. Lines without `key=value`
/// shape (version token, END marker, comments) are ignored, so the format
/// can grow; values may contain `=` (split happens at the first one). The
/// whole-document assembly (version token, END marker, verbatim unknown
/// lines) lives in `device_flash.dart`.
Map<String, String> parseFlashKv(String text) {
  final kv = <String, String>{};
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    kv[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return kv;
}
