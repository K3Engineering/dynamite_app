const bool useMockBt = false;

const btServiceId = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
const btChrAdcFeedId = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const btChrKvs = "10adce11-68a6-450b-9810-ca11b39fd283";

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
