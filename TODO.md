# Dynamite App - TODO

## Web Platform Limitations
- [ ] **Session binary file storage on web**: `dart:io` is not available on web.
  Session metadata is stored in the DB (via IndexedDB/WASM), but the raw binary
  sample data cannot be written to files. Options:
  - Store binary data as blobs in IndexedDB
  - Use the File System Access API (limited browser support)
  - Accept web as view-only for historical data (record + DB metadata works)

## Tier 2 Features (next iteration)
- [ ] **Annotations & markers**: Tap to mark points during live recording
- [ ] **Auto-detect break events**: Detect sudden load drops
- [ ] **Region selection analysis**: Select a time range on a saved session for focused stats
- [ ] **Session comparison**: Overlay two sessions for side-by-side comparison
- [ ] **Calibration parsing**: Implement actual device calibration characteristic parsing
  (currently uses hardcoded defaults — see `bt_handling.dart` `_updateCalibration`)
- [ ] **Manual calibration flow**: Apply known weight, record, compute slope
- [ ] **Sampling rate configuration**: UI to set device sample rate via BLE write

## Tier 3 Features (future)
- [ ] Multi-device support (connect to multiple devices simultaneously)
- [ ] Cloud sync / backup of session data
- [ ] Report generation (formatted PDF with graph + stats)
- [ ] Threshold alerts (audible/visual alert when force exceeds a set value)
- [ ] Batch analysis (compute stats across multiple sessions)

## Technical Debt
- [ ] **Lost packet handling**: The BLE handler detects lost packets but doesn't
  surface this to the user (see `// TODO: signal lost packets` in `bt_handling.dart`)
- [ ] **Auto-reconnect**: No auto-reconnect on unexpected BLE disconnect
- [ ] **Session detail graph interactivity**: Currently static; needs pinch-zoom,
  pan, and tap-for-crosshair cursor
- [ ] **Share/system share sheet**: Export CSV + share via platform share sheet
- [ ] **Tests**: No tests exist; widget and integration tests needed
- [ ] **Session graph tare**: Session detail graph doesn't subtract tare from
  stored data (tare was applied at recording time but raw values are stored)
