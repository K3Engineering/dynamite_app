/// Wire-format constants for the device's ADC feed protocol.
library;

import 'dart:typed_data';

import '../models/device_profile.dart';

/// Bytes per sample on the wire: [kAdcChannelCount] channels x 3 bytes
/// (24-bit).
const int wireAdcSampleLength = 3 * kAdcChannelCount;

/// Packet header bytes (16-bit little-endian running sample counter).
const int wireAdcHeaderSize = 2;

/// Sample count implied by a notification length, or null if the payload is
/// not a whole number of frames. The protocol accepts any sample count —
/// the link MTU caps packet size in practice — but a packet holds at least
/// one frame: a sample counter with no samples has no protocol meaning.
int? adcSamplesInPacket(int length) {
  final payload = length - wireAdcHeaderSize;
  if (payload < wireAdcSampleLength) return null;
  if (payload % wireAdcSampleLength != 0) return null;
  return payload ~/ wireAdcSampleLength;
}

/// Encode one sample frame: [kAdcChannelCount] channel values as 24-bit
/// little-endian. Values are masked to 24 bits (callers clamp to the signed
/// 24-bit range as needed).
Uint8List encodeAdcFrame(List<int> channels) {
  final out = Uint8List(wireAdcSampleLength);
  for (int ch = 0; ch < kAdcChannelCount; ch++) {
    final v = channels[ch] & 0xFFFFFF;
    out[ch * 3] = v & 0xFF;
    out[ch * 3 + 1] = (v >> 8) & 0xFF;
    out[ch * 3 + 2] = (v >> 16) & 0xFF;
  }
  return out;
}

/// Encode one ADC feed packet: the 16-bit LE running sample [counter] (the
/// starting sample index of the packet) followed by the frames, one minimum.
Uint8List encodeAdcPacket({
  required int counter,
  required Iterable<Uint8List> frames,
}) {
  final n = frames.length;
  assert(n >= 1);
  final out = Uint8List(wireAdcHeaderSize + n * wireAdcSampleLength);
  out[0] = counter & 0xFF;
  out[1] = (counter >> 8) & 0xFF;
  int offset = wireAdcHeaderSize;
  for (final frame in frames) {
    assert(frame.length == wireAdcSampleLength);
    out.setAll(offset, frame);
    offset += wireAdcSampleLength;
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
    for (int i = 0; i < kAdcChannelCount; ++i)
      (1 << ((pga >> (4 * i)) & 0x7)).toDouble(),
  ];
}
