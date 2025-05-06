//import 'dart:io';
//import 'package:cross_file/cross_file.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bt_handling.dart' show BluetoothHandling;
import 'graph_page.dart' show GraphPage;
import 'bt_icon.dart' show BluetoothIndicator;

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final BluetoothHandling _bluetoothHandler;
  // Guards a set of buttons,
  // to prevent simultaneous action
  bool _buttonPressed = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bluetoothHandler = Provider.of<BluetoothHandling>(context);
    _bluetoothHandler.startProcessing(_onBtStateChange);
  }

  @override
  void dispose() {
    _bluetoothHandler.stopProcessing(_onBtStateChange);
    _bluetoothHandler.stopSession();

    super.dispose();
  }

  void _onBtStateChange() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: IconButton(
        onPressed: () {
          Navigator.pop(context);
        },
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startTop,
      body: Align(
        child: Column(
          children: [
            BluetoothIndicator(
              isScanning: _bluetoothHandler.isScanning,
              state: _bluetoothHandler.bluetoothState,
            ),
            _buttonScan(),
            _buttonBluetoothDevice(),
            _buttonRunStop(),
          ],
        ),
      ),
    );
  }

  Widget _buttonScan() {
    return FilledButton.tonal(
      onPressed: () async {
        if (!_buttonPressed) {
          _buttonPressed = true;
          await _bluetoothHandler.toggleScan();
          _buttonPressed = false;
        }
      },
      child: Text(
          _bluetoothHandler.isScanning ? 'Stop scanning' : 'Start scanning'),
    );
  }

  Widget _buttonBluetoothDevice() {
    if (_bluetoothHandler.devices.isEmpty) {
      return const FilledButton.tonal(
        onPressed: null,
        child: Text(''),
      );
    }

    void onConnect() async {
      if (!_buttonPressed) {
        _buttonPressed = true;
        await _bluetoothHandler
            .connectToDevice(_bluetoothHandler.devices[0].deviceId);
        _buttonPressed = false;
      }
    }

    return FilledButton.tonal(
      onPressed: onConnect,
      child: Text('Device: ${_bluetoothHandler.devices[0].name}'),
    );
  }

  Widget _buttonRunStop() {
    void onRunStop() async {
      if (_bluetoothHandler.sessionInProgress || _buttonPressed) {
        return;
      }
      _buttonPressed = true;
      _bluetoothHandler.dataHub.clear();
      _bluetoothHandler.toggleSession();
      _bluetoothHandler.stopProcessing(_onBtStateChange);
      final bool? res = await Navigator.push(
          context,
          MaterialPageRoute<bool>(
            builder: (_) => const GraphPage(),
          ));
      if (res != null) {
        _bluetoothHandler.startProcessing(_onBtStateChange);
      }
      _onBtStateChange();
      _buttonPressed = false;
    }

    String buttonText() {
      if (_bluetoothHandler.isSubscribed) {
        return _bluetoothHandler.sessionInProgress ? 'Stop' : 'Run';
      }
      return '';
    }

    return FilledButton.tonal(
      onPressed: _bluetoothHandler.isSubscribed ? onRunStop : null,
      child: Text(buttonText()),
    );
  }
}
