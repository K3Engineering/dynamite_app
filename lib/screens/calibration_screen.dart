import 'package:flutter/material.dart';

import '../widgets/calibration_view.dart';

/// The subpage host for the factory calibration view: the same
/// [CalibrationView] the Settings tab can render inline, on its own route.
/// Bake-off scaffolding — one of the two hosts survives; see the TODO in
/// settings_tab.dart.
class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Board calibration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [CalibrationView(deviceId: deviceId)],
      ),
    );
  }
}
