/// Wire-format constants for the device's ADC feed protocol.
///
/// This is the single source of truth for the packet layout shared by the
/// decoder ([AdcPacketDecoder]), the storage layer ([DataHub], which sizes its
/// buffers off the channel count), and the mock BLE device (which *encodes*
/// packets in this format).
library;

import 'dart:typed_data';

/// Bytes per sample on the wire: [nwNumAdcChan] channels x 3 bytes (24-bit).
const int nwAdcSampleLength = 12;

/// Samples per notification packet.
const int nwAdcNumSamples = 20;

const int nwNumAdcChan = 4;

/// Packet header bytes (16-bit little-endian running sample counter).
const int nwHeaderSize = 2;

/// Encode one sample frame: [nwNumAdcChan] channel values as 24-bit
/// little-endian. Values are masked to 24 bits (callers clamp to the signed
/// 24-bit range as needed).
Uint8List encodeAdcFrame(List<int> channels) {
  final out = Uint8List(nwAdcSampleLength);
  for (int ch = 0; ch < nwNumAdcChan; ch++) {
    final v = channels[ch] & 0xFFFFFF;
    out[ch * 3] = v & 0xFF;
    out[ch * 3 + 1] = (v >> 8) & 0xFF;
    out[ch * 3 + 2] = (v >> 16) & 0xFF;
  }
  return out;
}

/// Encode one ADC feed packet: the 16-bit LE running sample [counter] (the
/// starting sample index of the packet) followed by exactly [nwAdcNumSamples]
/// frames. The single packet encoder for the wire format — used by the demo
/// signal source and the mock BLE platform so they can never drift off-format
/// ([AdcPacketDecoder] decodes it).
Uint8List encodeAdcPacket({
  required int counter,
  required Iterable<Uint8List> frames,
}) {
  assert(
    frames.length == nwAdcNumSamples,
    'a packet holds exactly $nwAdcNumSamples frames',
  );
  final out = Uint8List(nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength);
  out[0] = counter & 0xFF;
  out[1] = (counter >> 8) & 0xFF;
  int offset = nwHeaderSize;
  for (final frame in frames) {
    assert(frame.length == nwAdcSampleLength);
    out.setAll(offset, frame);
    offset += nwAdcSampleLength;
  }
  return out;
}

/// Parse the per-channel PGA gains from the ADC config characteristic's
/// value (`AdcConfigNetworkData`, packed little-endian: version u8, id u16,
/// status u16, mode u16, clock u16, pga u16 — the GAIN register readback,
/// four 4-bit fields, gain = 2^field). Null on a short buffer or an unknown
/// struct version — a failed parse is a failed read, never a guessed gain.
List<double>? parseAdcConfigPgaGains(Uint8List b) {
  const structBytes = 11;
  if (b.length < structBytes || b[0] != 1) return null;
  final pga = b[9] | (b[10] << 8);
  return [
    for (int i = 0; i < nwNumAdcChan; ++i)
      (1 << ((pga >> (4 * i)) & 0x7)).toDouble(),
  ];
}
