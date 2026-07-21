import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'adc_protocol.dart';

/// Generates realistic demo-quality simulated signals roughly scaled to a
/// typical load cell (±2²³ FS). Emits real 1 kHz ADC packets to a callback.
class DemoSignalSource {
  Timer? _timer;
  int _counter = 0;
  int _globalSampleIndex = 0;
  final math.Random _rand = math.Random();

  /// Approximate standard normal distribution via Box-Muller.
  double _gaussian() {
    double u1 = _rand.nextDouble();
    final double u2 = _rand.nextDouble();
    // To avoid log(0)
    if (u1 < 1e-10) u1 = 1e-10;
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
  }

  void start(void Function(Uint8List) onData) {
    stop();
    _counter = 0;
    _globalSampleIndex = 0;

    // 20 ms timer emitting 1 packet (20 samples @ 1 kHz).
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final frames = <Uint8List>[];

      for (int i = 0; i < nwAdcNumSamples; i++) {
        // Time in seconds since start
        final double t = _globalSampleIndex / 1000.0;

        // --- Channel 1: ~4s Thrust Curve (repeating) ---
        // Ramp up, rough plateau, tail-off
        final double tThrust = t % 4.0;
        double ch1Raw = 0.0;
        if (tThrust < 0.5) {
          ch1Raw = (tThrust / 0.5) * 5000000;
        } else if (tThrust < 2.5) {
          ch1Raw = 5000000 + _gaussian() * 50000;
        } else if (tThrust < 3.2) {
          ch1Raw = 5000000 * (1.0 - (tThrust - 2.5) / 0.7);
        } else {
          ch1Raw = 0.0;
        }

        // --- Channel 2: Break Test (slow ramp-to-failure, instant drop) ---
        // Repeats every ~8s. Fails around 6s.
        final double tBreak = t % 8.0;
        double ch2Raw = 0.0;
        if (tBreak < 6.0) {
          // quadratic ramp
          ch2Raw = 100000.0 * (tBreak * tBreak);
        } else {
          // Snapped! Followed by ringing or just drop.
          ch2Raw = 0.0;
        }

        // --- Channel 3: Gentle 0.2 Hz sinusoidal load ---
        final double ch3Raw = 2000000 * math.sin(2 * math.pi * 0.2 * t);

        // --- Channel 4: Quiet noise floor ---
        const double ch4Raw = 0.0;

        // Add ±100 count gaussian noise floor to all channels
        final int c1 = (ch1Raw + _gaussian() * 100).toInt().clamp(
          -8388608,
          8388607,
        );
        final int c2 = (ch2Raw + _gaussian() * 100).toInt().clamp(
          -8388608,
          8388607,
        );
        final int c3 = (ch3Raw + _gaussian() * 100).toInt().clamp(
          -8388608,
          8388607,
        );
        final int c4 = (ch4Raw + _gaussian() * 100).toInt().clamp(
          -8388608,
          8388607,
        );

        frames.add(encodeAdcFrame([c1, c2, c3, c4]));

        _globalSampleIndex++;
      }

      onData(encodeAdcPacket(counter: _counter, frames: frames));
      // Bump counter by nwAdcNumSamples (20) to maintain continuity
      _counter = (_counter + nwAdcNumSamples) & 0xFFFF;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
