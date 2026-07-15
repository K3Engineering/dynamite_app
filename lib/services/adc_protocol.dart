/// Wire-format constants for the device's ADC feed protocol.
///
/// This is the single source of truth for the packet layout shared by the
/// decoder ([AdcPacketDecoder]), the storage layer ([DataHub], which sizes its
/// buffers off the channel count), and the mock BLE device (which *encodes*
/// packets in this format).
library;

/// Bytes per sample on the wire: [nwNumAdcChan] channels x 3 bytes (24-bit).
const int nwAdcSampleLength = 12;

/// Samples per notification packet.
const int nwAdcNumSamples = 20;

/// ADC channels streamed by the device.
const int nwNumAdcChan = 4;

/// Packet header bytes (16-bit little-endian running sample counter).
const int nwHeaderSize = 2;
