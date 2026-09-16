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

/// The signed 24-bit rails: every real sample value lies in
/// [adcMinValue]..[adcMaxValue], and values outside are the codec's reserved
/// territory (see SessionChunkCodec's gap sentinel). The ONE definition of
/// the converter's range — clip checks, the session codec, and synthetic
/// feeds all derive from here.
const int adcMaxValue = adcCountsPerPolarity - 1;
const int adcMinValue = -adcCountsPerPolarity;

// ---------------------------------------------------------------------------
// Board constants (analog chain), resolved from the device
// ---------------------------------------------------------------------------

/// The analog-chain constants converting one channel's raw counts: ADC
/// full-scale reference, AFE gain, the ADC's PGA gain, excitation voltage.
/// Resolved from the device at connect time (flash keys + ADC register
/// readback) — the app carries NO compiled defaults: a board without this
/// data shows raw counts only (see [UnprovisionedBoardCalibration]).
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
/// ADC's PGA readback ([pgaGains] — always present: an unreadable ADC config
/// fails the connection upstream). Null when the flash holds NONE of the
/// constant keys: an unprovisioned board, a legal state (new or
/// factory-reset units stream raw counts only). Throws [FormatException] on
/// a partial or malformed set — the app never guesses a partial chain. The
/// caller ([DeviceFlash.fromKvs]) turns that throw into an
/// [InvalidBoardCalibration], so a bad provisioning still streams raw counts
/// with a warning rather than failing the connection.
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

/// Board-side calibration data of one ADC channel, as a sealed two-state:
///
/// - [CalibratedChannelBoard]: the characterized ladder resistors and the
///   raw readings the device produced in each of the [kCalPointCount]
///   differential configs, plus the resolved nominal chain. Conversion is a
///   piecewise-linear map through the five (raw, setpoint) points — it
///   absorbs ADC offset, the combined AFE/ADC/excitation gain, and ADC
///   nonlinearity between the cal points.
/// - [NominalChannelBoard]: no factory data; the resolved nominal chain is
///   the map.
///
/// Both variants convert. "No board data at all" (an unprovisioned unit,
/// or no connect-time read yet) is NOT a variant here: it is a null
/// `ChannelCalibration.board`, and raw counts are all that converts there.
///
/// The ladder and the readings are one datum (never a
/// characterized-rereading-over-nominal-ladder remix), and readings never
/// exist without resolved nominals (the parse paths only consult cal keys
/// once the board constants resolved); the measured members exist only on
/// [CalibratedChannelBoard].
sealed class ChannelBoardCalibration {
  const ChannelBoardCalibration._();

  /// The channel's resolved analog chain.
  ChannelNominals get nominals;

  /// Whether the channel has a calibration group. Board-level calibration
  /// is all-or-nothing: every channel is calibrated, or none is (see
  /// BoardCalibration.fromKv).
  bool get isCalibrated;

  /// The excitation anchor expressing the ratiometric map as mV. This value
  /// is the mV unit's entire uncertainty — the calibration is ratiometric,
  /// so the calibrated units never touch it. Deliberately not
  /// [ChannelNominals.excitationV]'s name: the nominal chain constant and
  /// the mV anchor are two roles that happen to resolve to the same number.
  double get displayExcitationV => nominals.excitationV;

  /// End-point sensitivity in counts per mV/V: measured on
  /// [CalibratedChannelBoard] (the chord through the two outermost cal
  /// points, which bracket a load cell's full-scale range — the slope of
  /// the conversion map where one number must stand in for it), the nominal
  /// chain's value on [NominalChannelBoard].
  double get sensitivityCountsPerMvV;

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

  /// Strict inverse of [toJson], honoring the variant structure: the
  /// nominal chain is required (a session with no board data at all stores
  /// a NULL board — see `ChannelCalibration.fromJson`), factory data is
  /// optional, but present-but-malformed data throws [FormatException] —
  /// one half of the ladder/readings pair without the other, or values
  /// failing [channelDataIsValid]. Replay never substitutes guessed
  /// values; the caller decides the damage policy (the session catalog
  /// marks the session damaged).
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

/// One complete calibration group: every channel's characterized ladder
/// resistors and readings, plus the `cal.*` provenance metadata describing
/// the run that produced them.
///
/// The group's PRESENCE marker is [date] (`cal.date`): a group with no date
/// is no group. A write of the group sets its data keys first and the date
/// last — a crash mid-write leaves data keys without a date. [parseCalGroup]
/// reads that as "no group" (it only sees the marker); the caller decides
/// what the residue means. [BoardCalibration.fromKv] treats it as corrupt
/// flash ([FormatException]) in both folders: the date is ALWAYS written by
/// the tool producing the group, so a missing date never means "the date is
/// unknown", and silently ignoring it would hide an interrupted recalibration
/// from the user who is expecting the new calibration to be in effect.
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

  /// One ladder/readings pair per ADC channel: the channel's entries
  /// validate together (see [ChannelBoardCalibration.channelDataIsValid]) —
  /// never a characterized-readings-over-nominal-ladder remix.
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

/// Parse one calibration group out of a key/value map. Null when the map
/// holds no `cal.date`: no calibration group (see [CalGroup] — the date is
/// the group's presence marker, and group keys without it are the CALLER's
/// policy domain, not checked here).
///
/// Throws [FormatException] on a present-but-invalid group: calibration is
/// all-or-nothing — every channel's ladder/readings must be present and
/// jointly valid (a factory always calibrates all channels in one document;
/// a partial set is corrupt flash, not a mixed instrument), and the numeric
/// metadata must be well-formed.
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
///
/// - [ProvisionedBoardCalibration]: the analog-chain constants resolved —
///   electrical (and, with load cells, force) units convert. Carries the
///   resolved nominals, one [ChannelBoardCalibration] per ADC channel, and
///   the `cal.*` provenance metadata.
/// - [UnprovisionedBoardCalibration]: flash holds no board data at all —
///   a new or factory-reset unit. The instrument streams raw counts only;
///   there is nothing per-channel to know.
/// - [InvalidBoardCalibration]: flash holds board data the app refuses to
///   adopt (partial/malformed constants or calibration). Like an
///   unprovisioned board it streams raw counts only, but it carries the
///   reason so the UI can tell the user their calibration is unreadable.
///
/// A failed READ (transport) still fails the connection upstream, so no
/// board object ever represents "couldn't read".
sealed class BoardCalibration {
  const BoardCalibration._();

  /// Parse the board half of a flash document from the FACTORY folder's
  /// key/value map (the two folders are parsed separately — see
  /// `DeviceFlash.fromKvs`; User-namespace keys never reach here).
  /// [pgaGains] is the ADC's GAIN-register readback (always present — the
  /// config read fails the connection upstream); it completes the board
  /// constants (see [resolveBoardConstants]).
  ///
  /// Throws [FormatException] on present-but-invalid board data: partial
  /// or malformed constants, orphaned calibration keys (channel entries or
  /// `cal.*` metadata without the constant chain or without `cal.date`, or
  /// calibration keys with no constant chain at all — the tooling writes the
  /// date last, so residue without it is an interrupted or corrupt write,
  /// not something to ignore), or a calibration group [parseCalGroup]
  /// rejects. Absent data is legal: no constant keys at all →
  /// [UnprovisionedBoardCalibration]; constants without a cal group →
  /// nominal channels. Unknown keys are ignored. [DeviceFlash.fromKvs]
  /// converts this throw into an [InvalidBoardCalibration].
  factory BoardCalibration.fromKv(
    Map<String, String> kv, {
    required List<double> pgaGains,
  }) {
    final nominals = resolveBoardConstants(kv, pgaGains: pgaGains);
    if (nominals == null) {
      // Unprovisioned means no owned calibration data, not merely missing
      // constants: calibration keys without the constant chain are a
      // fragment of a bad provisioning. Unknown keys are not board data.
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
      // No date marker: every calibration key must be absent outright.
      throw const FormatException(
        'board calibration: calibration keys without the cal.date marker',
      );
    }
    return ProvisionedBoardCalibration(nominals: nominals, calGroup: group);
  }
}

/// A provisioned board: the resolved analog-chain constants, one
/// [ChannelBoardCalibration] per ADC channel, and the optional calibration
/// group. No cal group → every channel converts through the nominal chain.
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

  /// The device's calibration group; null when flash holds constants but no
  /// calibration (a provisioned-but-never-calibrated board).
  final CalGroup? calGroup;

  /// One channel map per ADC channel, derived from [nominals] and
  /// [calGroup].
  final List<ChannelBoardCalibration> channels;

  /// Whether the runtime PGA config differs from the one the calibration was
  /// taken at — a stale-calibration guard (PGA gains are the only ADC config
  /// the runtime readback exposes). Null when the calibration recorded no
  /// gains (`cal.adc`).
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

/// A board with no board data in flash at all: a new or factory-reset
/// unit. Streams raw counts; electrical and force units report
/// unavailable (see `resolveUnitAvailability`).
class UnprovisionedBoardCalibration extends BoardCalibration {
  const UnprovisionedBoardCalibration() : super._();
}

/// A board whose flash held board data the app refused to adopt (see
/// [BoardCalibration.fromKv]): partial or malformed constants, or a
/// calibration group that failed validation. Streams raw counts like
/// [UnprovisionedBoardCalibration]; [detail] names the offending key for the
/// user-facing warning so they (or support) can see what is wrong.
class InvalidBoardCalibration extends BoardCalibration {
  const InvalidBoardCalibration(this.detail) : super._();

  /// The parser's reason, e.g. `board constants: bad adc_fsr: "soon"`.
  final String detail;
}
