import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    const bool normalDoubleCmp = identical(double.nan, double.nan);
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');

    return Scaffold(
      floatingActionButton: IconButton(
        onPressed: () {
          Navigator.pop(context);
        },
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startTop,
      body: const Align(
        child: Text(
          'Dynamite App.\n\nVersion: 1.0.0${dart2wasm ? '\nWASM' : ''}${normalDoubleCmp ? '' : '\nJS style cmp(double)'}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}
