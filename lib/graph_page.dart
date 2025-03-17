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

    _bluetoothHandler.initializeBluetooth(
        _processReceivedData, _dataTransformer._onUpdateCalibration, () {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _bluetoothHandler.dispose();
    super.dispose();
  }

  void _processReceivedData(String _, String __, Uint8List data) {
    if (_bluetoothHandler.sessionInProgress) {
      _dataTransformer._parseDataPacket(data, _appendGraphData, _onEndOfData);
    }
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
      if (_bluetoothHandler.sessionInProgress) {
        final File f = File('DynoData.txt');
        f.writeAsStringSync(_dataTransformer._rawData.toString());
      } else {
        for (var list in chartDataCh) {
          list.clear();
        }
        _dataTransformer._clear();
      }
      _bluetoothHandler.toggleSession();
    }

    final String title;
    if (_bluetoothHandler.isSubscribed) {
      title = _bluetoothHandler.sessionInProgress ? 'Stop' : 'Run';
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
      floatingActionButton: IconButton(
        onPressed: () {
          Navigator.pop(context);
        },
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startTop,
      body: Row(
        children: [
          Column(
            children: [
              BluetoothIndicator(bluetoothService: _bluetoothHandler),
              FilledButton.tonal(
                onPressed: () {
                  unawaited(_bluetoothHandler.toggleScan());
                },
                child: Text(_bluetoothHandler.isScanning
                    ? 'Stop scanning'
                    : 'Start scanning'),
              ),
              _buttonRunStop(),
              Text(_dataTransformer._taring ? 'Tare' : ''),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CustomPaint(
                    foregroundPainter: _DynoPainter(_dataTransformer),
                    child: const SizedBox(
                      width: 600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: _bluetoothHandler.isSubscribed
                  ? _graphPageLineChart()
                  : BluetoothDeviceList(bluetoothService: _bluetoothHandler),
            ),
          ),
        ],
      ),
    );
  }
}

class _DynoPainter extends CustomPainter {
  final _DataTransformer _data;

  _DynoPainter(this._data);

  static Color _lineColor(int idx) {
    if (idx == 1) return Colors.deepOrangeAccent;
    return Colors.blueAccent;
  }

  @override
  void paint(Canvas canvas, Size size) {
    Paint p1 = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0;

    canvas.drawRect(
        Rect.fromPoints(Offset(0, 0), Offset(size.width, size.height)), p1);

    p1.strokeWidth = 0.2;
    double step = size.height / 8;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p1);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p1);
    }

    if (_data._rawData[0].isEmpty) return;

    double dataMax = 1;
    for (int line = 0; line < _data._rawData.length; ++line) {
      final double p = _data._rawMax[line] - _data._tare[line];
      if (p > dataMax) dataMax = p.toDouble();
    }

    final int sz = _data._rawData[0].length;
    final double xScale = size.width / (sz > size.width ? sz : size.width);
    final double yScale = size.height / dataMax;

    double toY(int n, int line) {
      return size.height -
          (_data._rawData[line][n] - _data._tare[line]) * yScale;
    }

    for (int line = 0; line < _DataTransformer.numGraphLines; ++line) {
      final graph = Path();
      graph.moveTo(0, toY(0, line));
      for (int i = 1; i < sz; ++i) {
        graph.lineTo(i * xScale, toY(i, line));
      }
      p1.strokeWidth = 2;
      p1.color = _lineColor(line);
      canvas.drawPath(graph, p1);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _DataTransformer {
  static const int numGraphLines = 2;
  // TODO: this is preliminary implementation
  final Float64List _tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  final List<List<int>> _rawData = List.generate(
    _DataTransformer.numGraphLines,
    (_) => <int>[],
    growable: true,
  );
  final Int64List _rawMax = Int64List(numGraphLines);
  static const int _tareWindow = 1024;
  static const double _defaultSlope = 0.0001117587;
  static const int _samplesPerSec = 1000;
  int _timeTick = 0;
  _DeviceCalibration _deviceCalibration = _DeviceCalibration(0, _defaultSlope);

  void _clear() {
    _timeTick = 0;
    for (int i = 0; i < numGraphLines; ++i) {
      _rawData[i].clear();
      _rawMax[i] = 0;
      _tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  bool get _taring => (_timeTick > 0) && (_timeTick <= _tareWindow);

  bool _addTare(int val, int idx) {
    if (_timeTick < _tareWindow) {
      _runningTotal[idx] += val;
    } else if (_timeTick == _tareWindow) {
      _tare[idx] = _runningTotal[idx].toDouble() / _tareWindow;
      _runningTotal[idx] = 0;
    } else {
      return false;
    }
    return true;
  }

  void _addData(int val, int idx) {
    _rawData[idx].add(val);
    if (val > _rawMax[idx]) _rawMax[idx] = val;
  }

  void _onUpdateCalibration(Uint8List data) {
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
          if (!_addTare(res, idx)) {
            _addData(res, idx);
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
            selected: device.deviceId == bluetoothService.selectedDeviceId,
            onTap: () =>
                unawaited(bluetoothService.connectToDevice(device.deviceId)),
          );
        },
      );
    }

    return Column(
      children: [
        bluetoothService.isScanning
            ? const CircularProgressIndicator()
            : const Padding(
                padding: EdgeInsets.all(18.0),
              ),
        Flexible(
          child: deviceList(),
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
