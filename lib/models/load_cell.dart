import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Load cells: certificate profiles and the device's rig slots (app-writable
// flash namespace). Everything here is a property of a CELL (or a slot
// holding one): capacity and certificate sensitivity — never an ADC count.
// The interface board's factory calibration lives in board_calibration.dart,
// and the vocabulary stays separate: a cell has a zero BALANCE (a
// certificate property this app does not store), a board has a zero OFFSET.
// ---------------------------------------------------------------------------

/// Number of load cell slots on a device. The first [kAdcChannelCount] slots are
/// the channels (the plugged-in rig); the rest are spares carried on the
/// device. Constant for the first prototype.
const int kRigSlotCount = 10;

String rigSlotTitle(int i) =>
    i < kAdcChannelCount ? 'CH ${i + 1}' : 'Slot ${i + 1}';

/// One populated device slot: the cell it holds.
class RigSlot {
  const RigSlot({required this.cell});

  final LoadCellProfile cell;

  @override
  bool operator ==(Object other) => other is RigSlot && other.cell == cell;

  @override
  int get hashCode => cell.hashCode;
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

  LoadCellProfile? cellAt(int i) => slots[i]?.cell;

  /// Cells converting the four ADC channels (slots 0–3), nulls included.
  List<LoadCellProfile?> get channelCells => [
    for (int i = 0; i < kAdcChannelCount; ++i) cellAt(i),
  ];

  /// Channel row titles: the cell's name when the user set one, the
  /// channel-anchored spec line for an unnamed cell, or the bare channel
  /// name when no cell is assigned. The anchor keeps an unnamed cell
  /// readable in channel-bound contexts (stats table, tare sheet, session
  /// labels); the settings' slot list renders [LoadCellProfile.title]
  /// directly and never sees this composition.
  List<String> get channelTitles => [
    for (int i = 0; i < kAdcChannelCount; ++i)
      switch (cellAt(i)) {
        null => rigSlotTitle(i),
        final cell when cell.name.isNotEmpty => cell.name,
        final cell => '${rigSlotTitle(i)} · ${cell.valuesLine}',
      },
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
    }
  }
}

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

  /// Strict parse: capacity and sensitivity must be positive finite
  /// numbers (a malformed certificate value would poison every force
  /// conversion), else [FormatException]. Unknown keys are ignored, so the
  /// format can grow. The caller decides the damage policy (rig history
  /// drops the entry; session snapshots flag the whole column).
  factory LoadCellProfile.fromJson(Map<String, dynamic> json) {
    double req(Object? v, String key) {
      final d = v is num ? v.toDouble() : double.nan;
      if (!d.isFinite || d <= 0) {
        throw FormatException('load cell: bad $key: $v');
      }
      return d;
    }

    final name = json['name'];
    return LoadCellProfile(
      name: name is String ? name : '',
      capacityKg: req(json['capacityKg'], 'capacityKg'),
      sensitivityMvV: req(json['sensitivityMvV'], 'sensitivityMvV'),
    );
  }
}
