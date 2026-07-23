import '../services/adc_protocol.dart';

/// Analog front-end constants (fixed by hardware): the load cell signal
/// passes a 101x gain stage into a 24-bit bipolar ADC with a 1.2V full-scale
/// reference. The calibration layers built on top (board, load cell) live in
/// this file.
const double adcFullScaleV = 1.2;
const double frontEndGain = 101.0;
const int adcCountsPerPolarity = 1 << 23; // 24-bit bipolar: 2^23 per side

/// mV at the load cell output per ADC count (nominal chain).
const double rawToMvMultiplier =
    adcFullScaleV / adcCountsPerPolarity / frontEndGain * 1000.0;

/// ADC counts per mV at the load cell output (nominal chain).
const double countsPerMvAtCellOutput = 1.0 / rawToMvMultiplier;

/// Nominal excitation voltage, assumed when no better information exists
/// (a channel without factory calibration, or a blank flash).
const double nominalExcitationV = 4.53;

/// Nominal ADC counts per mV/V of load cell output: 1 mV/V under
/// [nominalExcitationV] is 4.53 mV at the cell output.
const double nominalCountsPerMvV = countsPerMvAtCellOutput * nominalExcitationV;

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

/// Nominal resistor values used when a channel's characterized values are
/// absent from flash.
const List<double> nominalLadderResistors = <double>[
  10000,
  10,
  10,
  10,
  10,
  10000,
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

/// Factory board calibration of one ADC channel: the characterized ladder
/// resistors and the raw readings the device produced in each of the
/// [kCalPointCount] differential configs.
///
/// Conversion is a piecewise-linear map through the five (raw, setpoint)
/// points — it absorbs ADC offset, the combined AFE/ADC/excitation gain, and
/// ADC nonlinearity between the cal points. A channel without factory data
/// ([readings] == null) falls back to the nominal chain
/// ([nominalCountsPerMvV], zero offset), which is exactly the pre-calibration
/// behavior.
class ChannelBoardCalibration {
  ChannelBoardCalibration({List<double>? resistors, List<double>? readings})
    : resistors = List.unmodifiable(resistors ?? nominalLadderResistors),
      readings = _validatedReadings(readings) {
    assert(this.resistors.length == kLadderResistorCount);
    final r = this.readings;
    if (r != null) {
      // Sort the five points ascending by raw reading for interpolation.
      final order = [for (int k = 0; k < kCalPointCount; ++k) k]
        ..sort((a, b) => r[a].compareTo(r[b]));
      final sp = ladderSetpointsMvV(this.resistors);
      _sortedRaw = [for (final k in order) r[k]];
      _sortedSetpoints = [for (final k in order) sp[k]];
    }
  }

  /// Reject degenerate readings (duplicate points would divide by zero
  /// during interpolation) by treating the channel as uncalibrated.
  static List<double>? _validatedReadings(List<double>? r) {
    if (r == null) return null;
    assert(r.length == kCalPointCount);
    if (r.toSet().length != r.length) return null;
    return List.unmodifiable(r);
  }

  /// Characterized ladder resistors (6), or nominal values.
  final List<double> resistors;

  /// Factory-averaged raw counts per config, in [kCalPointCount] storage
  /// order; null when the channel has no factory calibration.
  final List<double>? readings;

  bool get isFactoryCalibrated => readings != null;

  /// Setpoints (mV/V) per config, derived from [resistors].
  List<double> get setpoints => ladderSetpointsMvV(resistors);

  late final List<double> _sortedRaw;
  late final List<double> _sortedSetpoints;

  /// Map an absolute raw ADC reading to mV/V of excitation via the piecewise
  /// map. Out-of-range readings extend the outermost segment. Readings are
  /// absolute (offset included): net values come from subtracting the map at
  /// the tare point — see [ChannelCalibration.netMvV].
  double mvVFromRaw(double raw) {
    final r = readings;
    if (r == null) return raw / nominalCountsPerMvV;
    final xs = _sortedRaw;
    final ys = _sortedSetpoints;
    if (raw <= xs[0]) {
      return ys[0] + (raw - xs[0]) * (ys[1] - ys[0]) / (xs[1] - xs[0]);
    }
    for (int i = 1; i < xs.length; ++i) {
      if (raw <= xs[i]) {
        return ys[i - 1] +
            (raw - xs[i - 1]) * (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1]);
      }
    }
    final n = xs.length - 1;
    return ys[n] + (raw - xs[n]) * (ys[n] - ys[n - 1]) / (xs[n] - xs[n - 1]);
  }

  // -- Diagnostics ----------------------------------------------------------

  /// ADC offset in counts: the dead-short (t3,t3) reading measures it
  /// directly. 0 for an uncalibrated channel.
  double get offsetCounts => readings?[2] ?? 0;

  /// Terminal slope in counts per mV/V: the end-to-end slope between the two
  /// outermost cal points (which bracket a load cell's full-scale range).
  double get spanCountsPerMvV {
    final r = readings;
    if (r == null) return nominalCountsPerMvV;
    final sp = setpoints;
    return (r[0] - r[kCalPointCount - 1]) / (sp[0] - sp[kCalPointCount - 1]);
  }

  /// Excitation voltage implied by [spanCountsPerMvV] and the nominal AFE/ADC
  /// chain. Not a measurement of the excitation pin — it folds in AFE gain
  /// and ADC reference errors, which is exactly why the ratiometric
  /// calibration needs no separate excitation knowledge.
  double get effectiveExcitationV => spanCountsPerMvV / countsPerMvAtCellOutput;

  /// Terminal nonlinearity (ppm of half-span output, signed): deviation of
  /// the inner cal point from the straight line between the zero and the
  /// outer point of the same side. This is the datasheet terminal-straight-
  /// line definition, not a regression. 0 without factory data.
  double terminalNonlinearityPpm({required bool positiveSide}) {
    final r = readings;
    if (r == null) return 0;
    final sp = setpoints;
    // Storage order: 0 = +FS, 1 = +mid, 2 = zero, 3 = -mid, 4 = -FS.
    final iFs = positiveSide ? 0 : 4;
    final iMid = positiveSide ? 1 : 3;
    final lineAtMid =
        r[2] + (r[iFs] - r[2]) * (sp[iMid] - sp[2]) / (sp[iFs] - sp[2]);
    return (r[iMid] - lineAtMid) / (r[iFs] - r[2]).abs() * 1e6;
  }

  /// Session-snapshot serialization (recorded sessions carry the calibration
  /// they were taken with, so playback converts identically later).
  Map<String, dynamic> toJson() => {'r': resistors, 'raw': ?readings};

  /// Tolerant inverse of [toJson]: missing/malformed entries degrade to
  /// nominal resistors / no readings rather than throwing.
  factory ChannelBoardCalibration.fromJson(Map<String, dynamic> json) {
    List<double>? numList(Object? v, int count) {
      if (v is! List || v.length != count) return null;
      final out = <double>[];
      for (final e in v) {
        if (e is! num) return null;
        out.add(e.toDouble());
      }
      return out;
    }

    return ChannelBoardCalibration(
      resistors: numList(json['r'], kLadderResistorCount),
      readings: numList(json['raw'], kCalPointCount),
    );
  }
}

/// Board calibration of the whole device: one [ChannelBoardCalibration] per
/// ADC channel, plus optional factory metadata.
class BoardCalibration {
  BoardCalibration({
    required this.channels,
    this.factoryDate,
    this.excitationMv,
  }) : assert(channels.length == nwNumAdcChan);

  final List<ChannelBoardCalibration> channels;

  /// Factory calibration date string as written in flash (`cal.date`), if any.
  final String? factoryDate;

  /// Factory DMM reading of the excitation (`cal.exc.mv`), if any.
  final double? excitationMv;

  /// Every channel on the nominal chain (no factory data anywhere).
  factory BoardCalibration.nominal() => BoardCalibration(
    channels: [
      for (int i = 0; i < nwNumAdcChan; ++i) ChannelBoardCalibration(),
    ],
  );

  /// Parse the `key=value` calibration document. Never throws: structural
  /// problems degrade only the affected channel (or the whole board, if no
  /// usable keys exist) to nominal. Lines without `key=value` shape (version
  /// token, END marker, comments) are ignored, so the format can grow.
  factory BoardCalibration.parse(String text) {
    final kv = <String, String>{};
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      kv[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }

    List<double>? parseList(String? value, int count) {
      if (value == null) return null;
      final parts = value.split(',').map((s) => double.tryParse(s.trim()));
      if (parts.length != count || parts.any((v) => v == null)) return null;
      return [for (final v in parts) v!];
    }

    return BoardCalibration(
      channels: [
        for (int i = 0; i < nwNumAdcChan; ++i)
          ChannelBoardCalibration(
            resistors: parseList(kv['ch$i.r'], kLadderResistorCount),
            readings: parseList(kv['ch$i.raw'], kCalPointCount),
          ),
      ],
      factoryDate: kv['cal.date'],
      excitationMv: double.tryParse(kv['cal.exc.mv'] ?? ''),
    );
  }

  /// Serialize to the `key=value` document (the future write-to-device flow
  /// and tests). Channels without factory data emit resistors only.
  String serialize() {
    final b = StringBuffer('K3CAL1\n');
    if (factoryDate != null) b.writeln('cal.date=$factoryDate');
    if (excitationMv != null) b.writeln('cal.exc.mv=$excitationMv');
    for (int i = 0; i < channels.length; ++i) {
      final ch = channels[i];
      b.writeln('ch$i.r=${ch.resistors.join(',')}');
      final r = ch.readings;
      if (r != null) b.writeln('ch$i.raw=${r.join(',')}');
    }
    b.write('END');
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Load cell profiles
// ---------------------------------------------------------------------------

/// A load cell the user can assign to a channel: nameplate values plus an
/// optional serial and a [span] correction factor (set by user calibration
/// flows — known weight or comparison against a reference cell). The bank of
/// profiles lives app-side (AppSettings); a channel's assignment is just a
/// profile id.
class LoadCellProfile {
  LoadCellProfile({
    required this.id,
    this.name = '',
    required this.capacityKg,
    required this.sensitivityMvV,
    this.serial = '',
    this.span = 1.0,
  });

  /// Unique within the bank; minted at creation time.
  final String id;

  /// Display name. Empty means a generic profile — rendered from the values.
  String name;
  double capacityKg;
  double sensitivityMvV;
  String serial;

  /// User calibration factor (multiplies the nameplate sensitivity).
  double span;

  /// kgf per mV/V of measured signal.
  double get kgfPerMvV => capacityKg * span / sensitivityMvV;

  /// Human label: the name, or the values for generic profiles.
  String get title => name.isNotEmpty
      ? name
      : '${_trim(capacityKg)} kg · ${_trim(sensitivityMvV)} mV/V';

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'capacityKg': capacityKg,
    'sensitivityMvV': sensitivityMvV,
    'serial': serial,
    'span': span,
  };

  factory LoadCellProfile.fromJson(Map<String, dynamic> json) =>
      LoadCellProfile(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        capacityKg: (json['capacityKg'] as num).toDouble(),
        sensitivityMvV: (json['sensitivityMvV'] as num).toDouble(),
        serial: json['serial'] as String? ?? '',
        span: (json['span'] as num?)?.toDouble() ?? 1.0,
      );
}

// ---------------------------------------------------------------------------
// Combined per-channel calibration
// ---------------------------------------------------------------------------

/// Everything needed to convert one channel's raw ADC counts into display
/// units: the board piecewise map plus the assigned load cell (if any).
/// Net values are differences of the board map between a reading and the
/// tare point, so piecewise nonlinearity is applied on both sides.
class ChannelCalibration {
  const ChannelCalibration({required this.board, this.loadCell});

  final ChannelBoardCalibration board;

  /// Assigned load cell; null means "electrical units only" — force
  /// conversions report unavailable and the UI shows '—'.
  final LoadCellProfile? loadCell;

  double netMvV(double raw, double tare) =>
      board.mvVFromRaw(raw) - board.mvVFromRaw(tare);

  /// Net mV at the load cell output, via the board's effective excitation.
  double netMv(double raw, double tare) =>
      netMvV(raw, tare) * board.effectiveExcitationV;

  double netRaw(double raw, double tare) => raw - tare;

  /// Net force in kgf, or null when no load cell is assigned.
  double? netKgf(double raw, double tare) {
    final lc = loadCell;
    if (lc == null) return null;
    return netMvV(raw, tare) * lc.kgfPerMvV;
  }

  /// Local piecewise slope (mV/V per count) at [raw] — for derivative
  /// display, where differencing the map would need two evaluations anyway.
  double mvVPerCountAt(double raw) {
    const h = 0.5;
    return (board.mvVFromRaw(raw + h) - board.mvVFromRaw(raw - h)) / (2 * h);
  }

  /// Session-snapshot serialization.
  Map<String, dynamic> toJson() => {
    'board': board.toJson(),
    'cell': ?loadCell?.toJson(),
  };

  /// Tolerant inverse of [toJson]; a malformed cell entry drops just the
  /// load cell (electrical units still convert).
  factory ChannelCalibration.fromJson(Map<String, dynamic> json) {
    LoadCellProfile? cell;
    if (json['cell'] case final c?) {
      try {
        cell = LoadCellProfile.fromJson(Map<String, dynamic>.from(c as Map));
      } catch (_) {
        cell = null;
      }
    }
    final boardJson = switch (json['board']) {
      final b? => Map<String, dynamic>.from(b as Map),
      _ => const <String, dynamic>{},
    };
    return ChannelCalibration(
      board: ChannelBoardCalibration.fromJson(boardJson),
      loadCell: cell,
    );
  }
}
