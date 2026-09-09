import 'dart:typed_data';

// OTA wire opcodes, mirrored from dynamite_sampler_api.h (firmware
// ble_ota.cpp). The Control characteristic carries these as single bytes:
// host -> device requests, device -> host status replies.
const otaRequestOpcode = 0x01;
const otaDoneOpcode = 0x04;

const otaReadyReply = 0x00; // NOP: ready after the file-size write
const otaRequestAck = 0x02;
const otaRequestNak = 0x03;
const otaDoneAck = 0x05;
const otaDoneNak = 0x06;

/// The declared image size, 4-byte little-endian (OtaFileSizeType).
Uint8List encodeOtaFileSize(int size) => Uint8List(4)
  ..[0] = size & 0xFF
  ..[1] = (size >> 8) & 0xFF
  ..[2] = (size >> 16) & 0xFF
  ..[3] = (size >> 24) & 0xFF;
