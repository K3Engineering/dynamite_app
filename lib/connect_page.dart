import 'dart:async';
//import 'dart:io';
//import 'package:cross_file/cross_file.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'bt_handling.dart' show BluetoothHandling;
import 'graph_page.dart' show GraphPage;

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final BluetoothHandling _bluetoothHandler;
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
            _BluetoothIndicator(
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

class _BluetoothIndicator extends StatelessWidget {
  final bool isScanning;
  final AvailabilityState state;

  const _BluetoothIndicator({required this.isScanning, required this.state});

  @override
  Widget build(BuildContext context) {
    (IconData, Color) indicator() {
      if (isScanning) {
        return const (Icons.bluetooth_searching, Colors.lightBlue);
      }
      switch (state) {
        case AvailabilityState.poweredOn:
          return const (Icons.bluetooth, Colors.blueAccent);
        case AvailabilityState.poweredOff:
          return const (Icons.bluetooth_disabled, Colors.blueGrey);
        case AvailabilityState.unknown:
          return const (Icons.question_mark, Colors.yellow);
        case AvailabilityState.resetting:
          return const (Icons.question_mark, Colors.green);
        case AvailabilityState.unsupported:
          return const (Icons.stop, Colors.red);
        case AvailabilityState.unauthorized:
          return const (Icons.stop, Colors.orange);
        // ignore: unreachable_switch_default
        default:
          return const (Icons.question_mark, Colors.grey);
      }
    }

    final (IconData icon, Color color) = indicator();
    const double size = 48;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: size, color: color),
        if (isScanning)
          const SizedBox(
            height: size,
            width: size,
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }
}
