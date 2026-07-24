/// Fixture device-flash document served by the demo device and the mock BLE
/// platform, in the `key=value` flash format ([DeviceFlash.parse]).
///
/// Board values are plausible factory data — per-channel resistor
/// characterizations within tolerance, and readings carrying realistic
/// offset, gain error and slight nonlinearity. The slots describe a rig
/// matching the demo signal source: named cells on CH1/CH2, an unnamed cell
/// on CH3, CH4 empty (its channel is the quiet one), and a spare in slot 5 —
/// so the calibration and slot UIs have something interesting to show
/// without hardware. Physically self-consistent with the ladder math.
const String demoBoardCalibrationDoc = '''
K3CAL1
cal.date=2026-07-20
cal.exc.mv=4530.24
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997,10000.6
ch1.raw=6382935.5,3191479.7,-231.5,-3191962.7,-6383398.5
ch2.r=10000.1,10.0002,10.0004,9.9998,9.9996,9999.9
ch2.raw=6387638.4,3194602.6,1502.8,-3191597.0,-6384632.8
ch3.r=10000.4,10.0009,9.9996,10.0005,10.0002,10000.2
ch3.raw=6384540.7,3192235.0,64.9,-3192093.2,-6384410.9
lc0.name=Thrust cell
lc0.cap=200
lc0.sens=2
lc0.span=1.00037
lc0.mtime=2026-07-20T10:15:00.000Z
lc1.name=Break jig
lc1.cap=500
lc1.sens=2
lc1.span=0.99981
lc1.mtime=2026-07-20T10:15:00.000Z
lc2.cap=100
lc2.sens=2
lc2.span=1.0
lc4.name=Spare 50
lc4.cap=50
lc4.sens=2
lc4.span=1.0
END
''';
