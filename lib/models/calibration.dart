import 'dart:convert';

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
      final sp = setpoints;
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

  /// Setpoints (mV/V) per config, derived from [resistors]. Cached: pure
  /// function of the immutable [resistors], and per-sample conversion paths
  /// reach it via [spanCountsPerMvV]/[effectiveExcitationV].
  late final List<double> setpoints = ladderSetpointsMvV(resistors);

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
  double get offsetCounts => readings?[kCalIdxZero] ?? 0;

  /// Terminal slope in counts per mV/V: the end-to-end slope between the two
  /// outermost cal points (which bracket a load cell's full-scale range).
  /// Cached (see [setpoints]).
  late final double spanCountsPerMvV = switch (readings) {
    final r? =>
      (r[kCalIdxPosFs] - r[kCalIdxNegFs]) /
          (setpoints[kCalIdxPosFs] - setpoints[kCalIdxNegFs]),
    null => nominalCountsPerMvV,
  };

  /// Excitation voltage implied by [spanCountsPerMvV] and the nominal AFE/ADC
  /// chain. Not a measurement of the excitation pin — it folds in AFE gain
  /// and ADC reference errors, which is exactly why the ratiometric
  /// calibration needs no separate excitation knowledge. Cached (see
  /// [setpoints]).
  late final double effectiveExcitationV =
      spanCountsPerMvV / countsPerMvAtCellOutput;

  /// Terminal nonlinearity (ppm of half-span output, signed): deviation of
  /// the inner cal point from the straight line between the zero and the
  /// outer point of the same side. This is the datasheet terminal-straight-
  /// line definition, not a regression. 0 without factory data.
  double terminalNonlinearityPpm({required bool positiveSide}) {
    final r = readings;
    if (r == null) return 0;
    final sp = setpoints;
    final iFs = positiveSide ? kCalIdxPosFs : kCalIdxNegFs;
    final iMid = positiveSide ? kCalIdxPosMid : kCalIdxNegMid;
    final lineAtMid =
        r[kCalIdxZero] +
        (r[iFs] - r[kCalIdxZero]) *
            (sp[iMid] - sp[kCalIdxZero]) /
            (sp[iFs] - sp[kCalIdxZero]);
    return (r[iMid] - lineAtMid) / (r[iFs] - r[kCalIdxZero]).abs() * 1e6;
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

  /// Parse the board-calibration keys of a `key=value` flash document.
  /// Slot (`lcN.*`) and other unknown keys are ignored. Never throws — see
  /// [DeviceFlash.parse].
  factory BoardCalibration.parse(String text) =>
      BoardCalibration.fromKv(parseFlashKv(text));

  /// Build from an already-split key=value map (see [parseFlashKv]).
  /// Structural problems degrade only the affected channel to nominal.
  factory BoardCalibration.fromKv(Map<String, String> kv) {
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

  /// Serialize the board-calibration keys as a full flash document (no
  /// slots). Convenience wrapper over [DeviceFlash.serialize].
  String serialize() =>
      DeviceFlash(board: this, slots: RigSlots.empty()).serialize();
}

/// Split a `key=value` flash document into a map. Lines without `key=value`
/// shape (version token, END marker, comments) are ignored, so the format
/// can grow; values may contain `=` (split happens at the first one).
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

// ---------------------------------------------------------------------------
// Rig slots (load cells, app-writable flash namespace)
// ---------------------------------------------------------------------------

/// Number of load cell slots on a device. The first [nwNumAdcChan] slots are
/// the channels (the plugged-in rig); the rest are spares carried on the
/// device. Constant for the first prototype.
const int kRigSlotCount = 10;

/// One populated device slot: the cell plus the write timestamp from flash
/// (display metadata only — never a sync arbiter).
class RigSlot {
  const RigSlot({required this.cell, this.mtime});

  final LoadCellProfile cell;

  /// When this slot was written to the device, if known.
  final DateTime? mtime;

  RigSlot copyWith({LoadCellProfile? cell, DateTime? mtime}) =>
      RigSlot(cell: cell ?? this.cell, mtime: mtime ?? this.mtime);

  @override
  bool operator ==(Object other) =>
      other is RigSlot && other.cell == cell && other.mtime == mtime;

  @override
  int get hashCode => Object.hash(cell, mtime);
}

/// The device's ten load cell slots: identity is positional (slots 0–3 are
/// CH1–CH4). Immutable; edits produce new instances. The slot list is the
/// device's self-contained description of the rig — any host reading flash
/// can convert force from it alone.
class RigSlots {
  RigSlots(List<RigSlot?> slots)
    : slots = List.unmodifiable(
        slots.length == kRigSlotCount
            ? slots
            : throw ArgumentError('need $kRigSlotCount slots'),
      );

  final List<RigSlot?> slots;

  factory RigSlots.empty() => RigSlots(List.filled(kRigSlotCount, null));

  RigSlot? operator [](int i) => slots[i];

  /// The cell in slot [i], or null.
  LoadCellProfile? cellAt(int i) => slots[i]?.cell;

  /// Cells converting the four ADC channels (slots 0–3), nulls included.
  List<LoadCellProfile?> get channelCells => [
    for (int i = 0; i < nwNumAdcChan; ++i) cellAt(i),
  ];

  /// Channel row titles: the cell's title, or the bare channel name.
  List<String> get channelTitles => [
    for (int i = 0; i < nwNumAdcChan; ++i) cellAt(i)?.title ?? 'CH ${i + 1}',
  ];

  /// Per-slot content signatures (cell JSON, null for empty). Compared
  /// against a stored copy to detect "changed since your last visit"; mtime
  /// is deliberately excluded (a pure rewrite is not a change).
  List<String?> get signatures => [
    for (final s in slots) s == null ? null : jsonEncode(s.cell.toJson()),
  ];

  RigSlots withSlot(int i, RigSlot? slot) => RigSlots([
    for (int k = 0; k < kRigSlotCount; ++k) k == i ? slot : slots[k],
  ]);

  /// Swap the contents of slots [a] and [b] (the drag gesture): dragging a
  /// cell onto another slot exchanges them — nothing else moves.
  RigSlots withSwap(int a, int b) => RigSlots([
    for (int k = 0; k < kRigSlotCount; ++k)
      k == a
          ? slots[b]
          : k == b
          ? slots[a]
          : slots[k],
  ]);

  @override
  bool operator ==(Object other) {
    if (other is! RigSlots) return false;
    for (int i = 0; i < kRigSlotCount; ++i) {
      if (other.slots[i] != slots[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(slots);

  /// Parse the `lcN.*` keys of a flash document. A slot is populated iff its
  /// `cap` and `sens` keys parse to positive numbers; anything else degrades
  /// that one slot to empty.
  factory RigSlots.fromKv(Map<String, String> kv) {
    double? num(String? v) => v == null ? null : double.tryParse(v);
    return RigSlots([
      for (int i = 0; i < kRigSlotCount; ++i)
        switch ((num(kv['lc$i.cap']), num(kv['lc$i.sens']))) {
          (final cap?, final sens?) when cap > 0 && sens > 0 => RigSlot(
            cell: LoadCellProfile(
              name: kv['lc$i.name'] ?? '',
              capacityKg: cap,
              sensitivityMvV: sens,
            ),
            mtime: DateTime.tryParse(kv['lc$i.mtime'] ?? ''),
          ),
          _ => null,
        },
    ]);
  }

  /// Emit the populated slots' `lcN.*` lines (no trailing newline).
  /// Newlines in names are flattened (the doc is line-based); `=` in values
  /// is safe (parse splits at the first one).
  void serializeInto(StringBuffer b) {
    for (int i = 0; i < kRigSlotCount; ++i) {
      final s = slots[i];
      if (s == null) continue;
      final c = s.cell;
      if (c.name.isNotEmpty) {
        b.writeln('lc$i.name=${c.name.replaceAll(RegExp(r'\s+'), ' ')}');
      }
      b.writeln('lc$i.cap=${c.capacityKg}');
      b.writeln('lc$i.sens=${c.sensitivityMvV}');
      final m = s.mtime;
      if (m != null) b.writeln('lc$i.mtime=${m.toUtc().toIso8601String()}');
    }
  }
}

/// The full device flash document: the factory board calibration (read-only
/// to the app) plus the app-writable load cell slots. This is the unit the
/// calibration characteristic reads and writes.
class DeviceFlash {
  const DeviceFlash({required this.board, required this.slots});

  final BoardCalibration board;
  final RigSlots slots;

  /// Parse a whole flash document. Never throws: structural problems degrade
  /// only the affected piece (channel → nominal, slot → empty).
  factory DeviceFlash.parse(String text) {
    final kv = parseFlashKv(text);
    return DeviceFlash(
      board: BoardCalibration.fromKv(kv),
      slots: RigSlots.fromKv(kv),
    );
  }

  /// Serialize the whole document. The app only ever writes with [slots] it
  /// intends to persist and [board] exactly as read — board keys round-trip
  /// verbatim (the app is not their owner, just their courier).
  String serialize() {
    final b = StringBuffer('K3CAL1\n');
    if (board.factoryDate != null) b.writeln('cal.date=${board.factoryDate}');
    if (board.excitationMv != null) {
      b.writeln('cal.exc.mv=${board.excitationMv}');
    }
    for (int i = 0; i < board.channels.length; ++i) {
      final ch = board.channels[i];
      b.writeln('ch$i.r=${ch.resistors.join(',')}');
      final r = ch.readings;
      if (r != null) b.writeln('ch$i.raw=${r.join(',')}');
    }
    slots.serializeInto(b);
    b.write('END');
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Load cell profiles
// ---------------------------------------------------------------------------

/// A load cell as the app knows it: capacity plus the exact sensitivity
/// from its calibration certificate — e.g. 2.007 mV/V at full scale, not
/// the nominal "2 mV/V class" number. Profiles are pure values: identity
/// comes from WHERE a profile sits (a device slot, a history entry), not
/// from an id.
class LoadCellProfile {
  LoadCellProfile({
    this.name = '',
    required this.capacityKg,
    required this.sensitivityMvV,
  });

  /// Display name. Empty means a generic profile — rendered from the values.
  final String name;
  final double capacityKg;

  /// Exact mV/V at full capacity (the calibration-certificate value).
  final double sensitivityMvV;

  /// kgf per mV/V of measured signal.
  double get kgfPerMvV => capacityKg / sensitivityMvV;

  /// Human label: the name, or the values for generic profiles.
  String get title => name.isNotEmpty
      ? name
      : '${_trim(capacityKg)} kg · ${_trim(sensitivityMvV)} mV/V';

  /// The values line, e.g. `100 kg · 2.007 mV/V`. Shown wherever the cell's
  /// numbers matter next to its name.
  String get valuesLine =>
      '${_trim(capacityKg)} kg · ${_trim(sensitivityMvV)} mV/V';

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  LoadCellProfile copyWith({
    String? name,
    double? capacityKg,
    double? sensitivityMvV,
  }) => LoadCellProfile(
    name: name ?? this.name,
    capacityKg: capacityKg ?? this.capacityKg,
    sensitivityMvV: sensitivityMvV ?? this.sensitivityMvV,
  );

  @override
  bool operator ==(Object other) =>
      other is LoadCellProfile &&
      other.name == name &&
      other.capacityKg == capacityKg &&
      other.sensitivityMvV == sensitivityMvV;

  @override
  int get hashCode => Object.hash(name, capacityKg, sensitivityMvV);

  Map<String, dynamic> toJson() => {
    'name': name,
    'capacityKg': capacityKg,
    'sensitivityMvV': sensitivityMvV,
  };

  /// Tolerant parse: unknown keys are ignored, so the format can grow.
  factory LoadCellProfile.fromJson(Map<String, dynamic> json) =>
      LoadCellProfile(
        name: json['name'] as String? ?? '',
        capacityKg: (json['capacityKg'] as num).toDouble(),
        sensitivityMvV: (json['sensitivityMvV'] as num).toDouble(),
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
