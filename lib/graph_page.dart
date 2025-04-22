import 'dart:async';
import 'dart:collection';
//import 'dart:io';
//import 'package:cross_file/cross_file.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'bt_handling.dart' show BluetoothHandling, DataHub;

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});

  @override
  State<GraphPage> createState() => _GraphPageState();
}

typedef ScaleConfigItem = ({int limit, int delta});

class _GraphPageState extends State<GraphPage> {
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

  late BluetoothHandling _bluetoothHandler;

  @override
  void initState() {
    super.initState();
    _initGraphics();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bluetoothHandler = Provider.of<BluetoothHandling>(context);
    _bluetoothHandler.setListener(
      () {
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _bluetoothHandler.resetListener();
    _bluetoothHandler.stopSession();

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
          BluetoothIndicator(
            isScanning: _bluetoothHandler.isScanning,
            state: _bluetoothHandler.bluetoothState,
          ),
          _buttonScan(),
          _buttonBluetoothDevice(),
          _buttonRunStop(),
          Expanded(
            child: CustomPaint(
              foregroundPainter: _DynoPainter(_bluetoothHandler.dataHub),
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
        _bluetoothHandler.dataHub.clear();
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
    if (_bluetoothHandler.devices.isEmpty) {
      return const FilledButton.tonal(
        onPressed: null,
        child: Text(''),
      );
    }

    void onConnect() {
      unawaited(_bluetoothHandler
          .connectToDevice(_bluetoothHandler.devices[0].deviceId));
    }

    return FilledButton.tonal(
      onPressed: onConnect,
      child: Text('Device: ${_bluetoothHandler.devices[0].name}'),
    );
  }
}

class _DynoPainter extends CustomPainter {
  final DataHub _data;

  _DynoPainter(this._data) : super(repaint: _data);

  static Color _lineColor(int idx) {
    if (idx == 1) return Colors.deepOrangeAccent;
    return Colors.blueAccent;
  }

  double extremum() {
    double dataMax = 10000; // Above noise level
    for (int line = 0; line < _data.rawMax.length; ++line) {
      final double x = _data.rawMax[line] - _data.tare[line];
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

    if (_data.rawSz == 0) return;

    ScaleConfigItem findScale(double val, List<ScaleConfigItem> list) {
      return list.firstWhere((e) => val < e.limit,
          orElse: () => (limit: 0, delta: 1));
    }

    double secondsToPos(int sec) {
      return sec * DataHub.samplesPerSec * graphSz.width / _data.rawSz;
    }

    final double xSpanSec = _data.rawSz / DataHub.samplesPerSec;
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
      return y * _data.deviceCalibration.slope;
    }

    double kiloToY(int kilo) {
      return kilo * graphSz.height / dataMax / _data.deviceCalibration.slope;
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

    for (int line = 0; line < DataHub.numGraphLines; ++line) {
      final path1 = Path();
      //final path2 = Path();

      double toY(double val) {
        final double y = graphSz.height -
            (val - _data.tare[line]) * graphSz.height / dataMax;
        if (y < 0) {
          return 0;
        }
        if (y > graphSz.height) {
          return graphSz.height;
        }
        return y;
      }

      path1.moveTo(0, toY(_data.tare[line]));
      final int graphSzWidth = graphSz.width.toInt();
      for (int i = 0, j = 0; i < graphSzWidth; ++i) {
        //int mn = 100000000, mx = 0;
        int total = 0;
        final int start = j;
        for (; (j * graphSzWidth < i * _data.rawSz) && (j < _data.rawSz); ++j) {
          final int v = _data.rawData[line][j];
          total += v;
          //mx = (v > mx) ? v : mx;
          //mn = (v < mn) ? v : mn;
        }

        if (start < j) {
          final double avg = total / (j - start);
          path1.lineTo(i.toDouble(), toY(avg));
          //path2.moveTo(i.toDouble(), toY(mn.toDouble()));
          //path2.lineTo(i.toDouble(), toY(mx.toDouble()));
        }
      }

      pen.color = _lineColor(line);
      canvas.drawPath(path1, pen..strokeWidth = 2);
      //canvas.drawPath(path2, pen..strokeWidth = 0);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class BluetoothIndicator extends StatelessWidget {
  final bool isScanning;
  final AvailabilityState state;

  const BluetoothIndicator(
      {super.key, required this.isScanning, required this.state});

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
