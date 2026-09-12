import 'dart:typed_data';

// OTA wire opcodes, mirrored from dynamite_sampler_api.h (firmware
// ble_ota.cpp). Host -> device on the Control characteristic: a 5-byte
// REQUEST (opcode + u32 LE image size) or a 1-byte DONE. Device -> host:
// one status byte per handled Control write.
const otaRequestOpcode = 0x01;
const otaDoneOpcode = 0x04;

const otaRequestAck = 0x02;
const otaRequestNak = 0x03;
const otaDoneAck = 0x05;
const otaDoneNak = 0x06;

/// REQUEST carrying the declared image size (OtaFileSizeType, little-endian)
/// in the payload tail.
Uint8List encodeOtaRequest(int fileSize) => Uint8List(5)
  ..[0] = otaRequestOpcode
  ..[1] = fileSize & 0xFF
  ..[2] = (fileSize >> 8) & 0xFF
  ..[3] = (fileSize >> 16) & 0xFF
  ..[4] = (fileSize >> 24) & 0xFF;
