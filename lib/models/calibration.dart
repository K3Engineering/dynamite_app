/// The calibration model, split by domain. This barrel re-exports all three
/// files so existing importers keep working; new code should import the
/// narrow file it needs.
///
/// * `board_calibration.dart` — the interface board's factory calibration:
///   analog-chain constants, the cal ladder, the piecewise map. Counts-land.
/// * `load_cell.dart` — load cell certificate profiles and the device's rig
///   slots. kgf-land; never an ADC count.
/// * `device_flash.dart` — the whole flash document (board + slots) and the
///   per-channel join ([ChannelCalibration]) the unit layer consumes.
library;

export 'board_calibration.dart';
export 'device_flash.dart';
export 'load_cell.dart';
