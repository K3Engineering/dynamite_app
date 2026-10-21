const btServiceId = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
const btChrAdcFeedId = "6e08f21a-c056-43ed-890a-d72bb0f7c12f";
const btChrKvs = "10adce11-68a6-450b-9810-ca11b39fd283";

// ADC configuration readout (read-only): the register snapshot the firmware
// took at boot — the per-channel PGA gains come from its GAIN register.
const btChrAdcConfig = "adcc0f19-2575-4502-9a48-0e99974eb34f";

// OTA firmware update (see ble_ota.cpp): Control carries the session
// handshake opcodes (write + single-byte status notifies), Data carries raw
// image bytes (write only).
const otaServiceId = "6f2ecf77-fd83-42a8-86de-4be9713bd53c";
const btChrOtaControl = "66815c6b-2b3f-4142-8a0a-bc34644eae01";
const btChrOtaData = "09999d81-f1f6-4e31-8946-590220cc99af";

// Bluetooth SIG Device Information service (0x180A) and its read-only string
// characteristics — the static device identity, read once per link. Firmware
// publishes all of them (see setupDeviceInfo() in ble_proc.cpp).
const btSvcDeviceInfo = "0000180a-0000-1000-8000-00805f9b34fb";
const btChrDisManufacturer = "00002a29-0000-1000-8000-00805f9b34fb";
const btChrDisModel = "00002a24-0000-1000-8000-00805f9b34fb";
// On the Web Bluetooth GATT blocklist (privacy): unreadable on web.
const btChrDisSerial = "00002a25-0000-1000-8000-00805f9b34fb";
const btChrDisHardwareRev = "00002a27-0000-1000-8000-00805f9b34fb";
const btChrDisFirmwareRev = "00002a26-0000-1000-8000-00805f9b34fb";
