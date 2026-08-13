import 'calibration.dart';

/// The ADC reference both variants share (fixed by the converter, not the
/// board): 24-bit bipolar on a 1.2 V full-scale reference.
const double _adcFullScaleV = 1.2;

/// The pro's fixed front-end gain (x101). Per-board flash nominals
/// ([ChannelNominals]) carry the measured values for conversions; this
/// compiled device-MODEL default remains because the variant itself is not
/// yet device-reported (see [DeviceCapabilities]).
const double _proFrontEndGain = 101.0;

/// The two measurement front-ends the app talks to. Both are BLE MCUs with a
/// 24-bit bipolar ADC on a 1.2 V reference; they differ in the gain stage
/// between the load cell output and the ADC input.
enum DeviceVariant {
  /// Signal -> fixed-gain analog front-end (x101) -> ADC.
  pro,

  /// Signal -> programmable-gain amplifier on the ADC -> ADC. The gain is a
  /// device setting, so the model carries it (unlike the pro's fixed x101).
  pga,
}

/// What the connected device physically is and what its analog chain can do.
///
/// NOT piped through from the hardware yet: every consumer is fed
/// [DeviceCapabilities.pro] for now (see `DataHub.deviceCapabilities`). The
/// eventual source is device-reported — flash `hw.*` keys (which
/// `DeviceFlash.extraLines` already round-trips untouched) or advertisement
/// manufacturer data (the parse TODO in `BleLinkManager._onScanResult`).
///
/// Note what is deliberately NOT here: the ADC clip point. Clipping is a
/// property of the 24-bit converter itself — +/-2^23 raw counts on both
/// devices — so it lives with the wire/calibration constants
/// ([adcCountsPerPolarity]) and `ChannelLimits`, not in this per-variant
/// model. The variant's gain only changes what that rail MEANS at the cell
/// output (see [cellOutputFullScaleMv]).
class DeviceCapabilities {
  const DeviceCapabilities._(this.variant, this.afeGain);

  /// The fixed-gain device: signal -> x101 AFE -> ADC.
  static const DeviceCapabilities pro = DeviceCapabilities._(
    DeviceVariant.pro,
    _proFrontEndGain,
  );

  /// The PGA device with [pgaGain] programmed on the ADC. Unused until
  /// device reporting lands (the app always assumes [pro] today).
  factory DeviceCapabilities.pga(double pgaGain) =>
      DeviceCapabilities._(DeviceVariant.pga, pgaGain);

  final DeviceVariant variant;

  /// Gain between the load cell output and the ADC input: [_proFrontEndGain]
  /// (x101) on the pro, the programmed PGA gain on the other device.
  final double afeGain;

  /// ADC full-scale referred to the load cell output, in mV: the 1.2 V
  /// reference divided by the front-end gain. Pro: ~11.88 mV (~2.62 mV/V at
  /// the nominal 4.53 V excitation — a 3 mV/V cell can rail this device
  /// before reaching its rated full scale).
  double get cellOutputFullScaleMv => _adcFullScaleV / afeGain * 1000.0;

  /// Display name for the UI ('Pro' / 'PGA').
  String get modelName => switch (variant) {
    DeviceVariant.pro => 'Pro',
    DeviceVariant.pga => 'PGA',
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceCapabilities &&
      other.variant == variant &&
      other.afeGain == afeGain;

  @override
  int get hashCode => Object.hash(variant, afeGain);
}
