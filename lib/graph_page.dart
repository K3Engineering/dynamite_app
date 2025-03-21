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
        minY: 0,
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
        for (final list in chartDataCh) {
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
  Widget build(final BuildContext context) {
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
                  padding: const EdgeInsets.all(32),
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
              padding: const EdgeInsets.fromLTRB(8, 144, 8, 8),
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

  static Path gridPath(Size size) {
    final Path grid = Path();
    final double step = size.height / 8;
    for (double x = step; x < size.width; x += step) {
      grid.moveTo(x, 0);
      grid.lineTo(x, size.height);
    }
    for (double y = step; y <= size.height; y += step) {
      grid.moveTo(0, y);
      grid.lineTo(size.width, y);
    }
    return grid;
  }

  double extremum() {
    double dataMax = 10000; // Above noise level
    for (int line = 0; line < _data._rawData.length; ++line) {
      final double x = _data._rawMax[line] - _data._tare[line];
      dataMax = (x > dataMax) ? x : dataMax;
    }
    return dataMax;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0;

    canvas.drawRect(
        Rect.fromPoints(const Offset(0, 0), Offset(size.width, size.height)),
        pen);

    if (_data._rawData[0].isEmpty) return;

    final double dataMax = extremum();
    final Path grid = gridPath(size);
    pen.strokeWidth = 0.2;
    canvas.drawPath(grid, pen);

    for (int line = 0; line < _DataTransformer.numGraphLines; ++line) {
      final int dataSz = _data._rawData[line].length;
      final double xScale = dataSz / size.width;
      final double yScale = size.height / dataMax;

      double toY(double val) {
        final double y = size.height - (val - _data._tare[line]) * yScale;
        if (y < 0) {
          return 0;
        }
        if (y > size.height) {
          return size.height;
        }
        return y;
      }

      final graph = Path();
      final graph2 = Path();
      graph.moveTo(0, toY(_data._tare[line]));
      for (int i = 0, j = 0; i < size.width; ++i) {
        double mn = 100000000, mx = 0;
        double total = 0;
        final int start = j;
        for (; (j < dataSz) && (j < i * xScale); ++j) {
          final int v = _data._rawData[line][j];
          total += v;
          mx = (v > mx) ? v.toDouble() : mx;
          mn = (v < mn) ? v.toDouble() : mn;
        }

        if (start < j) {
          final double avg = total / (j - start);
          graph.lineTo(i.toDouble(), toY(avg));
          graph2.moveTo(i.toDouble(), toY(mn));
          graph2.lineTo(i.toDouble(), toY(mx));
        }
      }

      pen.strokeWidth = 2;
      pen.color = _lineColor(line);
      canvas.drawPath(graph, pen);
      pen.strokeWidth = 0;
      canvas.drawPath(graph2, pen);
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
      _tare[idx] = _runningTotal[idx] / (_tareWindow - 1);
      _runningTotal[idx] = 0;
    } else {
      return false;
    }
    return true;
  }

  void _addData(int val, int idx) {
    _rawData[idx].add(val);
    if (val > _rawMax[idx]) {
      _rawMax[idx] = val;
    }
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
    final double x = count.toDouble() / _samplesPerSec;
    final double y = (val.toDouble() - _tare[idx]) * _deviceCalibration._slope;
    return FlSpot(x, y);
  }

  void _parseDataPacket(Uint8List data,
      void Function(FlSpot spot, int idx) graphCb, void Function() eodCb) {
    const int sampleLength = 15;
    if (data.isEmpty || data.length % sampleLength != 0) {
      debugPrint('Incorrect buffer size received');
    }

    for (int packetStart = 0;
        packetStart < data.length;
        packetStart += sampleLength) {
      assert(packetStart + sampleLength <= data.length);
      // final status = (data[packetStart + 1] << 8) | data[packetStart];
      // final crc = data[packetStart + 14];
      _timeTick++;
      const int numAdcChan = 4;
      for (int i = 0; i < numAdcChan; ++i) {
        final int baseIndex = packetStart + 2 + i * 3;
        final int res = ((data[baseIndex + 2] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex])
            .toSigned(24);

        final int idx = _chanToLine(i);
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
  Widget build(final BuildContext context) {
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
                padding: EdgeInsets.all(18),
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
  Widget build(final BuildContext context) {
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

    final (IconData icon, Color color) = indicator();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Icon(icon, color: color),
    );
  }
}
