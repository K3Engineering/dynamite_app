/// Wire-format constants for the device's ADC feed protocol.
library;

import 'dart:typed_data';

/// Bytes per sample on the wire: [nwNumAdcChan] channels x 3 bytes (24-bit).
const int nwAdcSampleLength = 12;

/// Max samples per notification (ATT payload 244 / Android).
const int nwAdcNumSamples = 20;

/// Min samples per notification (ATT MTU 185 / iOS).
const int nwAdcMinSamples = 15;

const int nwNumAdcChan = 4;

/// Packet header bytes (16-bit little-endian running sample counter).
const int nwHeaderSize = 2;

/// Sample count implied by a notification length, or null if it is not a
/// complete 15–20 sample packet.
int? adcSamplesInPacket(int length) {
  final payload = length - nwHeaderSize;
  if (payload < nwAdcMinSamples * nwAdcSampleLength) return null;
  if (payload > nwAdcNumSamples * nwAdcSampleLength) return null;
  if (payload % nwAdcSampleLength != 0) return null;
  return payload ~/ nwAdcSampleLength;
}

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
/// starting sample index of the packet) followed by 15–20 frames.
Uint8List encodeAdcPacket({
  required int counter,
  required Iterable<Uint8List> frames,
}) {
  final n = frames.length;
  assert(n >= nwAdcMinSamples && n <= nwAdcNumSamples);
  final out = Uint8List(nwHeaderSize + n * nwAdcSampleLength);
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
