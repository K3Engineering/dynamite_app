/// Facts about the device itself, below both the wire protocol and the flash
/// schema. The protocol's frame size and the flash document's `ch$i`/`lc$i`
/// key families derive from the channel count; the ADC's data rate derives
/// from the oscillator (the CLOCK-register OSR field picks the divisor
/// against it). Both live here rather than in either consumer.
library;

/// ADC channels on the device. Fixed for the first prototype.
const int kAdcChannelCount = 4;

/// The device's ADC core clock (Hz): the 8.192 MHz on-chip oscillator the
/// modulator and data rate derive from. Hardwired, so a constant — what the
/// CLOCK-register readback selects is the divisor (see
/// `parseAdcConfig` in adc_protocol.dart).
const int kAdcClockHz = 8192000;
