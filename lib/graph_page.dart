import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';
//import 'dart:io';
//import 'package:cross_file/cross_file.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'bt_handling.dart' show BluetoothHandling;

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});

  @override
  State<GraphPage> createState() => _GraphPageState();
}

typedef ScaleConfigItem = ({int limit, int delta});

class _GraphPageState extends State<GraphPage> {
  final BluetoothHandling _bluetoothHandler = BluetoothHandling();

  final _DataHub _dataHub = _DataHub();

  // Seconds
  static const List<ScaleConfigItem> _xScaleConfig = [
    (limit: 5, delta: 1),
    (limit: 10, delta: 2),
    (limit: 30, delta: 5),
    (limit: 60, delta: 10),
    (limit: 120, delta: 20),
    (limit: 300, delta: 30),
    (limit: 600, delta: 60),
  ];
  static final Map<int, ui.Paragraph> _xPreparedLabels = HashMap();

  // Kilogram
  static const List<ScaleConfigItem> _yScaleConfig = [
    (limit: 5, delta: 1),
    (limit: 10, delta: 2),
    (limit: 20, delta: 5),
    (limit: 50, delta: 10),
    (limit: 100, delta: 20),
    (limit: 200, delta: 50),
    (limit: 500, delta: 100),
    (limit: 1000, delta: 200),
  ];
  static final Map<int, ui.Paragraph> _yPreparedLabels = HashMap();

  @override
  void initState() {
    super.initState();
    _initGraphics();
    _bluetoothHandler.initializeBluetooth(
        _processReceivedData, _dataHub._onUpdateCalibration, () {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _disposeGraphics();
    _bluetoothHandler.dispose();
    super.dispose();
  }

  static void _initGraphics() {
    for (final range in _xScaleConfig) {
      for (int j = range.delta; j <= range.limit; j += range.delta) {
        if (!_xPreparedLabels.containsKey(j)) {
          _xPreparedLabels[j] = _prepareAxisLabel(_formatTime(j));
        }
      }
    }
    for (final range in _yScaleConfig) {
      for (int j = range.delta; j <= range.limit; j += range.delta) {
        if (!_yPreparedLabels.containsKey(j)) {
          _yPreparedLabels[j] = _prepareAxisLabel(_formatForce(j));
        }
      }
    }
  }

  static void _disposeGraphics() {}

  static ui.Paragraph _prepareAxisLabel(String text) {
    final textStyle = ui.TextStyle(
      color: Colors.black,
      fontSize: 16,
    );
    final paragraphStyle =
        ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1);
    final paragraphBuilder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle);
    paragraphBuilder.addText(text);
    return paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 64));
  }

  static String _formatTime(int nSec) {
    if (nSec < 60) {
      return nSec.toString();
    }
    final String s = (nSec % 60 < 10) ? '0' : '';
    return '${nSec ~/ 60}:$s${nSec % 60}';
  }

  static String _formatForce(int nKg) {
    return nKg.toString();
  }

  void _processReceivedData(String _, String __, Uint8List data) {
    if (_bluetoothHandler.sessionInProgress) {
      _dataHub._parseDataPacket(data, () {
        setState(() {});
      });
    }
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
          Text(_dataHub._taring ? 'Tare' : ''),
          Expanded(
            child: CustomPaint(
              foregroundPainter: _DynoPainter(_dataHub),
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
        //-------------
        //final xf =
        //XFile.fromData(Uint8List.fromList(_dataTransformer._rawData[0]));
        //unawaited(xf.saveTo('DynoData.txt'));
      } else {
        _dataHub._clear();
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
  final _DataHub _data;

  _DynoPainter(this._data);

  static Color _lineColor(int idx) {
    if (idx == 1) return Colors.deepOrangeAccent;
    return Colors.blueAccent;
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

    const double leftSpace = 8;
    const double rightSpace = 44;
    const double bottomSpace = 24;

    canvas.translate(leftSpace, 0);
    final Size graphSz =
        Size(size.width - rightSpace, size.height - bottomSpace);
    canvas.drawRect(Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
        pen..strokeWidth = 0);

    final double dataMax = extremum();
    final Path grid = Path();

    if (_data._rawData[0].isEmpty) return;

    final int dataSz = _data._rawData[0].length;

    ScaleConfigItem findScale(double val, List<ScaleConfigItem> list) {
      return list.firstWhere((e) => val < e.limit,
          orElse: () => (limit: 0, delta: 1));
    }

    double secondsToPos(int sec) {
      return sec * _DataHub._samplesPerSec * graphSz.width / dataSz;
    }

    final double xSpanSec = dataSz / _DataHub._samplesPerSec;
    final ScaleConfigItem xC =
        findScale(xSpanSec, _GraphPageState._xScaleConfig);
    final double xMinorDelta = secondsToPos(xC.delta) / 2;
    for (double x = xMinorDelta; x < graphSz.width; x += xMinorDelta) {
      grid.moveTo(x, 0);
      grid.lineTo(x, graphSz.height);
    }
    for (int i = xC.delta; i < xSpanSec; i += xC.delta) {
      final double yPos = secondsToPos(i);
      final ui.Paragraph? par = _GraphPageState._xPreparedLabels[i];
      if (par != null) {
        canvas.drawParagraph(
            par, Offset(yPos - par.longestLine / 2, graphSz.height));
      }
    }

    double ySampleToKilo(double y) {
      return y * _data._deviceCalibration._slope;
    }

    double kiloToY(int kilo) {
      return kilo * graphSz.height / dataMax / _data._deviceCalibration._slope;
    }

    final double ySpanKilo = ySampleToKilo(dataMax);
    final ScaleConfigItem yC =
        findScale(ySpanKilo, _GraphPageState._yScaleConfig);
    final double yMinorDelta = kiloToY(yC.delta) / 2;
    for (double y = yMinorDelta; y < graphSz.height; y += yMinorDelta) {
      grid.moveTo(0, graphSz.height - y);
      grid.lineTo(graphSz.width, graphSz.height - y);
    }
    for (int i = yC.delta; i < ySpanKilo; i += yC.delta) {
      final double yPos = graphSz.height - kiloToY(i);
      final ui.Paragraph? par = _GraphPageState._yPreparedLabels[i];
      if (par != null) {
        canvas.drawParagraph(
            par, Offset(graphSz.width + par.height / 4, yPos - par.height / 2));
      }
    }
    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    for (int line = 0; line < _DataHub.numGraphLines; ++line) {
      final path1 = Path();
      final path2 = Path();

      double toY(double val) {
        final double y = graphSz.height -
            (val - _data._tare[line]) * graphSz.height / dataMax;
        if (y < 0) {
          return 0;
        }
        if (y > graphSz.height) {
          return graphSz.height;
        }
        return y;
      }

      path1.moveTo(0, toY(_data._tare[line]));
      final int graphSzWidth = graphSz.width.toInt();
      for (int i = 0, j = 0; i < graphSzWidth; ++i) {
        int mn = 100000000, mx = 0;
        int total = 0;
        final int start = j;
        for (; (j * graphSzWidth < i * dataSz) && (j < dataSz); ++j) {
          final int v = _data._rawData[line][j];
          total += v;
          mx = (v > mx) ? v : mx;
          mn = (v < mn) ? v : mn;
        }

        if (start < j) {
          final double avg = total / (j - start);
          path1.lineTo(i.toDouble(), toY(avg));
          path2.moveTo(i.toDouble(), toY(mn.toDouble()));
          path2.lineTo(i.toDouble(), toY(mx.toDouble()));
        }
      }

      pen.color = _lineColor(line);
      canvas.drawPath(path1, pen..strokeWidth = 2);
      canvas.drawPath(path2, pen..strokeWidth = 0);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _DataHub {
  static const int numGraphLines = 2;
  final Float64List _tare = Float64List(numGraphLines);
  final Float64List _runningTotal = Float64List(numGraphLines);
  final List<List<int>> _rawData = List.generate(
    _DataHub.numGraphLines,
    (_) => <int>[],
    growable: false,
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
