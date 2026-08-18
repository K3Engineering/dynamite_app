/// Facts about the device itself, below both the wire protocol and the flash
/// schema. Currently one constant: the ADC channel count. The protocol's
/// frame size and the flash document's `ch$i`/`lc$i` key families both derive
/// from it, so it lives here rather than in either consumer.
library;

/// ADC channels on the device. Fixed for the first prototype.
const int kAdcChannelCount = 4;
