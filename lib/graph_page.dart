import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
      _dataTransformer._parseDataPacket(data, _onEndOfData);
    }
  }

  void _onEndOfData() {
    setState(() {}); // Update UI layer
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
      body: Column(
        children: [
          BluetoothIndicator(bluetoothService: _bluetoothHandler),
          _buttonScan(),
          _buttonBluetoothDevice(),
          _buttonRunStop(),
          Text(_dataTransformer._taring ? 'Tare' : ''),
          Expanded(
            child: CustomPaint(
              foregroundPainter: _DynoPainter(_dataTransformer),
              size: MediaQuery.of(context).size,
              // child: Container(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buttonScan() {
    return FilledButton.tonal(
      onPressed: () {
        unawaited(_bluetoothHandler.toggleScan());
      },
      child: Text(
          _bluetoothHandler.isScanning ? 'Stop scanning' : 'Start scanning'),
    );
  }

  Widget _buttonRunStop() {
    void onRunStop() {
      if (_bluetoothHandler.sessionInProgress) {
        //final f = File('DynoData.txt');
        //f.writeAsStringSync(_dataTransformer._rawData.toString());
      } else {
        _dataTransformer._clear();
      }
      _bluetoothHandler.toggleSession();
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

  Widget _buttonBluetoothDevice() {
    final String currentDeviceId = _bluetoothHandler.devices.isNotEmpty
        ? _bluetoothHandler.devices[0].deviceId
        : '';

    void onConnect() {
      unawaited(_bluetoothHandler.connectToDevice(currentDeviceId));
    }

    return FilledButton.tonal(
      onPressed: currentDeviceId.isNotEmpty ? onConnect : null,
      child: Text('Device: $currentDeviceId'),
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
    final grid = Path();
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
    final pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke;

    canvas.translate(8, 0);
    final frame = Rect.fromLTRB(0, 0, size.width - 32, size.height - 24);
    canvas.drawRect(frame, pen..strokeWidth = 0);

    final double dataMax = extremum();
    final Path grid = gridPath(frame.size);
    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    if (_data._rawData[0].isEmpty) return;

    final int dataSz = _data._rawData[0].length;
    final double xScale = dataSz / frame.size.width;
    final double yScale = frame.size.height / dataMax;

    int labelIndex = 1;
    for (; labelIndex < _DataTransformer._xScaleSteps.length; ++labelIndex) {
      if (_DataTransformer._xScaleSteps[labelIndex] > dataSz) {
        break;
      }
    }
    labelIndex--;
    final markPos = Offset(
        _DataTransformer._xScaleSteps[labelIndex] / xScale, frame.bottom);

    canvas.drawLine(markPos, markPos.translate(0, 8), pen..strokeWidth = 0);
    canvas.drawParagraph(
        _DataTransformer._xScaleLabels[labelIndex], markPos.translate(4, 0));

    for (int line = 0; line < _DataTransformer.numGraphLines; ++line) {
      double toY(double val) {
        final double y = frame.size.height - (val - _data._tare[line]) * yScale;
        if (y < 0) {
          return 0;
        }
        if (y > frame.size.height) {
          return frame.size.height;
        }
        return y;
      }

      final graph = Path();
      final graph2 = Path();
      graph.moveTo(0, toY(_data._tare[line]));
      for (int i = 0, j = 0; i < frame.size.width; ++i) {
        int mn = 100000000, mx = 0;
        int total = 0;
        final int start = j;
        for (; (j < i * xScale) && (j < dataSz); ++j) {
          final int v = _data._rawData[line][j];
          total += v;
          mx = (v > mx) ? v : mx;
          mn = (v < mn) ? v : mn;
        }

        if (start < j) {
          final double avg = total / (j - start);
          graph.lineTo(i.toDouble(), toY(avg));
          graph2.moveTo(i.toDouble(), toY(mn.toDouble()));
          graph2.lineTo(i.toDouble(), toY(mx.toDouble()));
        }
      }

      pen.color = _lineColor(line);
      canvas.drawPath(graph, pen..strokeWidth = 2);
      canvas.drawPath(graph2, pen..strokeWidth = 0);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _DataTransformer {
  static const int numGraphLines = 2;
  final Float64List _tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  final List<List<int>> _rawData = List.generate(
    _DataTransformer.numGraphLines,
    (_) => <int>[],
    growable: false,
  );
  final Int64List _rawMax = Int64List(numGraphLines);
  static const int _tareWindow = 1024;
  static const double _defaultSlope = 0.0001117587;
  static const int _samplesPerSec = 1000;
  int _timeTick = 0;
  _DeviceCalibration _deviceCalibration = _DeviceCalibration(0, _defaultSlope);
  static final List<int> _xScaleSteps = [];
  static final List<ui.Paragraph> _xScaleLabels = [];

  _DataTransformer() {
    if (_xScaleSteps.isNotEmpty) return;

    _xScaleSteps.add(5 * _samplesPerSec);
    int n = 10 * _samplesPerSec;
    for (; n < 60 * _samplesPerSec; n += 10 * _samplesPerSec) {
      _xScaleSteps.add(n);
    }
    for (; n < 120 * _samplesPerSec; n += 15 * _samplesPerSec) {
      _xScaleSteps.add(n);
    }
    for (; n <= 600 * _samplesPerSec; n += 30 * _samplesPerSec) {
      _xScaleSteps.add(n);
    }
    for (int i = 0; i < _xScaleSteps.length; ++i) {
      _xScaleLabels.add(_stepTitle(_xScaleSteps[i]));
    }
  }

  static ui.Paragraph _stepTitle(int n) {
    n = n ~/ _samplesPerSec;
    final textStyle = ui.TextStyle(
      color: Colors.black,
      fontSize: 16,
    );
    final paragraphStyle =
        ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1);
    final paragraphBuilder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle);
    if (n < 60) {
      paragraphBuilder.addText(n.toString());
    } else {
      final s = (n % 60 < 10) ? '0' : '';
      paragraphBuilder.addText('${n ~/ 60}:$s${n % 60}');
    }
    return paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 64));
  }

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

  void _parseDataPacket(Uint8List data, void Function() eodCb) {
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

    final (IconData icon, Color color) = indicator();
    return Stack(
      clipBehavior: Clip.none,
      alignment: AlignmentDirectional.center,
      children: [
        Icon(icon, color: color),
        if (bluetoothService.isScanning) const CircularProgressIndicator(),
        const SizedBox(
          height: 56,
          width: 24,
        ),
      ],
    );
  }
}
