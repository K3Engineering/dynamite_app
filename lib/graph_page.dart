import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'bt_handling.dart' show BluetoothHandling;

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  final String title = 'Graph';

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final BluetoothHandling _bluetoothHandler = BluetoothHandling();

  final List<List<FlSpot>> chartDataCh = List.generate(
    _DataTransformer.numGraphLines,
    (_) => <FlSpot>[],
    growable: false,
  );

  final _DataTransformer _dataTransformer = _DataTransformer();

  @override
  void initState() {
    super.initState();

    _bluetoothHandler.initializeBluetooth();
    _bluetoothHandler.onNewDataCallback = _processReceivedData;
    _bluetoothHandler.onCalibrationCallback =
        _dataTransformer._updateCalibration;
    _bluetoothHandler.onStateChange = () {
      setState(() {}); // Update UI layer
    };
  }

  @override
  void dispose() {
    _bluetoothHandler.dispose();
    super.dispose();
  }

  void _processReceivedData(Uint8List data) {
    _dataTransformer._parseDataPacket(data, _appendGraphData, _onEndOfData);
  }

  void _onEndOfData() {
    setState(() {}); // Update UI layer
  }

  void _appendGraphData(FlSpot val, int idx) {
    chartDataCh[idx].add(val);
  }

  Widget _graphPageLineChart() {
    Color lineColor(int idx) {
      if (idx == 1) return Colors.deepOrangeAccent;
      return Colors.blueAccent;
    }

    return LineChart(
      LineChartData(
        lineBarsData: List<LineChartBarData>.generate(
            chartDataCh[0].isNotEmpty ? chartDataCh.length : 0,
            (i) => LineChartBarData(
                  spots: chartDataCh[i],
                  dotData: const FlDotData(
                    show: false,
                  ),
                  color: lineColor(i),
                ),
            growable: false),
        titlesData: const FlTitlesData(
            topTitles: AxisTitles(), leftTitles: AxisTitles()),
        minY: 0, // TODO: negative values
        clipData: const FlClipData.all(),
      ),
      duration: Duration.zero,
      curve: Curves.linear,
    );
  }

  Widget _buttonRunStop() {
    void onRunStop() {
      assert(_bluetoothHandler.selectedDevice != null);

      if (_dataTransformer._sessionInProgress) {
        final File f = File('DynoData.txt');
        f.writeAsStringSync('Raw ADC data here...');
      } else {
        for (var list in chartDataCh) {
          list.clear();
        }
        _dataTransformer._timeTick = 0;
      }
      _dataTransformer._sessionInProgress =
          !_dataTransformer._sessionInProgress;

      setState(() {}); // Update UI layer
    }

    final String title;
    if (_bluetoothHandler.isSubscribed) {
      title = _dataTransformer._sessionInProgress ? 'Stop' : 'Run';
    } else {
      title = '';
    }
    return FilledButton.tonal(
      onPressed: _bluetoothHandler.isSubscribed ? onRunStop : null,
      child: Text(title),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          BluetoothIndicator(bluetoothService: _bluetoothHandler),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: BluetoothDeviceList(bluetoothService: _bluetoothHandler),
          ),
          _buttonRunStop(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: _graphPageLineChart(),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          unawaited(_bluetoothHandler.toggleScan());
        },
        tooltip:
            _bluetoothHandler.isScanning ? 'Stop scanning' : 'Start scanning',
        child: Icon(_bluetoothHandler.isScanning ? Icons.stop : Icons.search),
      ),
    );
  }
}

class _DataTransformer {
  static const int numGraphLines = 2;
  // TODO: this is preliminary implementation
  final Float64List _tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  static const int _avgWindow = 1024;
  static const double _defaultSlope = 0.0001117587;
  static const int _samplesPerSec = 1000;
  bool _sessionInProgress = false;
  int _timeTick = 0;
  _DeviceCalibration _deviceCalibration = _DeviceCalibration(0, _defaultSlope);

  void _updateTare(int val, int idx) {
    if (_timeTick < _avgWindow) {
      _runningTotal[idx] += val;
    } else if (_timeTick == _avgWindow) {
      _tare[idx] = _runningTotal[idx].toDouble() / _avgWindow;
      _runningTotal[idx] = 0;
    }
  }

  void _updateCalibration(Uint8List data) {
    // TODO: implement calibration parsing
    _deviceCalibration = _DeviceCalibration(0, _defaultSlope);
    debugPrint(
        'Calibration ${_deviceCalibration._slope}, offset${_deviceCalibration._offset}');
  }

  static int _chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1; // No graph line for this chanel
  }

  FlSpot _transform(int count, int val, int idx) {
    double x = count.toDouble() / _samplesPerSec;
    double y = val.toDouble() - _tare[idx];
    y *= _deviceCalibration._slope;
    return FlSpot(x, y);
  }

  void _parseDataPacket(Uint8List data,
      void Function(FlSpot spot, int idx) graphCb, void Function() eodCb) {
    if (!_sessionInProgress) {
      return;
    }
    if (data.isEmpty || data.length % 15 != 0) {
      debugPrint('Incorrect buffer size received');
    }

    for (int packetStart = 0; packetStart < data.length; packetStart += 15) {
      assert(packetStart + 15 <= data.length);
      // final status = (data[packetStart + 1] << 8) | data[packetStart];
      // final crc = data[packetStart + 14];
      _timeTick++;
      const int numAdcChan = 4;
      for (int i = 0; i < numAdcChan; ++i) {
        final int baseIndex = packetStart + 2 + i * 3;
        int res = ((data[baseIndex + 2] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex])
            .toSigned(24);

        int idx = _chanToLine(i);
        if (idx >= 0) {
          if (_timeTick <= _avgWindow) {
            _updateTare(res, idx);
          } else {
            graphCb(_transform(_timeTick, res, idx), idx);
          }
        }
      }
    }
    eodCb();
  }
}

class _DeviceCalibration {
  _DeviceCalibration(this._offset, this._slope);
  final int _offset;
  final double _slope;
}

class BluetoothDeviceList extends StatelessWidget {
  final BluetoothHandling bluetoothService;

  const BluetoothDeviceList({super.key, required this.bluetoothService});

  @override
  Widget build(BuildContext context) {
    ListView deviceList() {
      return ListView.builder(
        itemCount: bluetoothService.devices.length,
        itemBuilder: (_, index) {
          final device = bluetoothService.devices[index];
          return ListTile(
            title: Text(device.name ?? 'Unknown Device'),
            subtitle: Text('Device ID: ${device.deviceId}'),
            selected:
                device.deviceId == bluetoothService.selectedDevice?.deviceId,
            onTap: () => unawaited(bluetoothService.connectToDevice(device)),
          );
        },
      );
    }

    return Column(
      children: [
        if (bluetoothService.isScanning) const CircularProgressIndicator(),
        Expanded(
          child: deviceList(),
        ),
        const Divider(),
        Flexible(
          // Use Flexible instead of Expanded here to ensure layout stability
          child: (bluetoothService.selectedDevice == null)
              ? SizedBox.shrink()
              : BluetoothServiceDetails(bluetoothService: bluetoothService),
        ),
      ],
    );
  }
}

class BluetoothServiceDetails extends StatelessWidget {
  final BluetoothHandling bluetoothService;

  const BluetoothServiceDetails({super.key, required this.bluetoothService});

  @override
  Widget build(BuildContext context) {
    ListView serviceList() {
      return ListView.builder(
        itemCount: bluetoothService.services.length,
        itemBuilder: (_, index) {
          final service = bluetoothService.services[index];
          return ListTile(
            title: Text('Service: ${service.uuid}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: service.characteristics
                  .map((char) => Text('Characteristic: ${char.uuid}'))
                  .toList(),
            ),
            onTap: () =>
                unawaited(bluetoothService.subscribeToAdcFeed(service)),
          );
        },
      );
    }

    return Column(
      children: [
        Text(
          'Connected to: ${bluetoothService.selectedDevice?.name ?? "Unknown Device"}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Expanded(
          child: (bluetoothService.services.isNotEmpty)
              ? serviceList()
              : const Text('No services found for this device.'),
        ),
      ],
    );
  }
}

class BluetoothIndicator extends StatelessWidget {
  final BluetoothHandling bluetoothService;

  const BluetoothIndicator({super.key, required this.bluetoothService});

  @override
  Widget build(BuildContext context) {
    (IconData, Color) indicator() {
      if (bluetoothService.isScanning) {
        return (Icons.bluetooth_searching, Colors.lightBlue);
      }
      switch (bluetoothService.bluetoothState) {
        case AvailabilityState.poweredOn:
          return (Icons.bluetooth, Colors.blueAccent);
        case AvailabilityState.poweredOff:
          return (Icons.bluetooth_disabled, Colors.blueGrey);
        case AvailabilityState.unknown:
          return (Icons.question_mark, Colors.yellow);
        case AvailabilityState.resetting:
          return (Icons.question_mark, Colors.green);
        case AvailabilityState.unsupported:
          return (Icons.stop, Colors.red);
        case AvailabilityState.unauthorized:
          return (Icons.stop, Colors.orange);
        // ignore: unreachable_switch_default
        default:
          return (Icons.question_mark, Colors.grey);
      }
    }

    var (icon, color) = indicator();
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Icon(icon, color: color),
    );
  }
}
