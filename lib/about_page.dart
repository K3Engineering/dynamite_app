import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    const bool normalDoubleCmp = identical(double.nan, double.nan);
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');

    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'Dynamite App.\n\nVersion: 1.0.0\n${dart2wasm ? 'WASM' : ''}\n${normalDoubleCmp ? '' : 'JS style cmp(double)'}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
