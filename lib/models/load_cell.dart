import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Load cells: certificate profiles and the device's rig slots (app-writable
// flash). A cell has a zero BALANCE, a board a zero OFFSET; the board's factory
// calibration lives in board_calibration.dart.
// ---------------------------------------------------------------------------

/// Number of load cell slots: the first [kAdcChannelCount] are the channels,
/// the rest spares.
const int kRigSlotCount = 10;

/// The exact load-cell-slot keys the app owns in the device's User
/// namespace. Unknown `lc*`-shaped keys are ignored on read and left alone
/// on write.
final Set<String> rigSlotKeys = Set.unmodifiable({
  for (int i = 0; i < kRigSlotCount; ++i) ...[
    'lc$i.name',
    'lc$i.cap',
    'lc$i.sens',
  ],
});

/// The canonical label for a slot/channel index; zero-based, matching the
/// device's physical labels.
String rigSlotTitle(int i) => i < kAdcChannelCount ? 'CH $i' : 'Slot $i';

/// One populated device slot: the cell it holds.
@immutable
class RigSlot {
  const RigSlot({required this.cell});

  final LoadCellProfile cell;

  @override
  bool operator ==(Object other) => other is RigSlot && other.cell == cell;

  @override
  int get hashCode => cell.hashCode;
}

/// The device's load cell slots; identity is positional. Immutable.
@immutable
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

  /// Channel row titles: the cell's name, else its spec line anchored to the
  /// channel, else the bare channel name. (The settings slot list renders
  /// [LoadCellProfile.title] directly instead.)
  List<String> get channelTitles => [
    for (int i = 0; i < kAdcChannelCount; ++i)
      switch (cellAt(i)) {
        null => rigSlotTitle(i),
        final cell when cell.name.isNotEmpty => cell.name,
        final cell => '${rigSlotTitle(i)} · ${cell.valuesLine}',
      },
  ];

  @useResult
  RigSlots withSlot(int i, RigSlot? slot) => RigSlots([
    for (int k = 0; k < kRigSlotCount; ++k) k == i ? slot : slots[k],
  ]);

  /// Swap the contents of slots [a] and [b].
  @useResult
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

  /// Parse the `lcN.*` keys (the User folder's slot document). A slot is
  /// populated iff `cap` and `sens` parse to positive finite numbers; anything
  /// else reads as empty (lenient: the app owns these keys and can repair them).
  factory RigSlots.fromKv(Map<String, String> kv) {
    double? num(String? v) => v == null ? null : double.tryParse(v);
    return RigSlots([
      for (int i = 0; i < kRigSlotCount; ++i)
        switch ((num(kv['lc$i.cap']), num(kv['lc$i.sens']))) {
          (final cap?, final sens?)
              when cap.isFinite && sens.isFinite && cap > 0 && sens > 0 =>
            RigSlot(
              cell: LoadCellProfile(
                name: kv['lc$i.name'] ?? '',
                capacityKg: cap,
                sensitivityMvV: sens,
              ),
            ),
          // Absent (or name-only) slot: no owned value to complain about.
          (null, null) => null,
          // Present but unrepairable: read as empty, with a dev-visible trace.
          _ => _rejectedSlot(i, kv),
        },
    ]);
  }

  /// The populated slots' `lcN.*` keys — the full set the device should hold
  /// (a save SETs these and DELs known slot keys it doesn't). The document is
  /// line-based, so newlines in names are flattened; `=` in values is safe
  /// (parsing splits at the first one). Integral values emit without a fraction
  /// so an unchanged rig diffs clean.
  Map<String, String> toKv() {
    String num(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return {
      for (int i = 0; i < kRigSlotCount; ++i)
        if (slots[i] case final s?) ...{
          if (s.cell.name.isNotEmpty)
            'lc$i.name': s.cell.name.replaceAll(RegExp(r'\s+'), ' '),
          'lc$i.cap': num(s.cell.capacityKg),
          'lc$i.sens': num(s.cell.sensitivityMvV),
        },
    };
  }
}

/// A slot whose `cap`/`sens` are present but unparseable: read as empty, with
/// a developer-visible trace.
RigSlot? _rejectedSlot(int i, Map<String, String> kv) {
  debugPrint(
    'RigSlots: ignoring slot $i with malformed cap/sens '
    '(cap=${kv['lc$i.cap']}, sens=${kv['lc$i.sens']})',
  );
  return null;
}

/// A load cell: capacity plus the exact certificate sensitivity (e.g. 2.007
/// mV/V, not a nominal class). Identity is positional, not an id.
@immutable
class LoadCellProfile {
  const LoadCellProfile({
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

  /// The values line, e.g. `100 kg · 2.007 mV/V`.
  String get valuesLine =>
      '${_trim(capacityKg)} kg · ${_trim(sensitivityMvV)} mV/V';

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @useResult
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

  /// Strict parse: capacity and sensitivity must be positive finite, else
  /// [FormatException]. Unknown keys are ignored. The caller decides the damage
  /// policy.
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
