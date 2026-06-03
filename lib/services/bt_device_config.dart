const bool useMockBt = false;

// const btDeviceUUID = "E4:B0:63:81:5B:19";
const btGattId = "a659ee73-460b-45d5-8e63-ab6bf0825942";
const btServiceId = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
const btChrAdcFeedId = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const btChrCalibration = "10adce11-68a6-450b-9810-ca11b39fd283";

const int nwAdcSampleLength = 12;
const int nwAdcNumSamples = 20;
const int nwNumAdcChan = 4;
const int nwHeaderSize = 2;

/// Sentinel value injected into the circular buffer when BLE packets are dropped.
/// Must be outside the valid range of the 24-bit ADC (-8388608 to 8388607).
const int kDroppedSampleSentinel = -2147483648; // Minimum Int32
