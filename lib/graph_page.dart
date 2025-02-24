import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:universal_ble/universal_ble.dart'
    show AvailabilityState, BleDevice, BleService;

import 'bt_handling.dart' show BluetoothHandling;

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  final String title = 'Graph';

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final BluetoothHandling _bluetoothHandler = BluetoothHandling();
  static const int _graphWindow = 200;
  bool _graphFilerAverage = true;

  final List<Queue<FlSpot>> chartDataCh = List.generate(
    _DataTransformer.numGraphLines,
    (_) => Queue<FlSpot>(),
    growable: false,
  );

  final AvgAdcData avgAdcData = AvgAdcData(_DataTransformer.numGraphLines);
  int _xVal = 0;

  @override
  void initState() {
    super.initState();

    _bluetoothHandler.initializeBluetooth();
    _bluetoothHandler.onNewDataCallback = processReceivedData;
    _bluetoothHandler.isScanning.addListener(() {
      setState(() {}); // Update UI layer
    });
  }

  void processReceivedData(Uint8List data) {
    _DataTransformer._parseAndAppendDataPacket(
        data, _appendGraphData, _onEndOfData);
  }

  void _onEndOfData() {
    setState(() {}); // Update UI layer
  }

  void _appendGraphData(int val, int idx) {
    avgAdcData._add(val, idx);

    if (idx == 0) {
      _xVal++;
    }
    chartDataCh[idx].add(FlSpot(_xVal.toDouble(),
        val.toDouble() - (_graphFilerAverage ? avgAdcData.getAvg(idx) : 0)));
    if (chartDataCh[idx].length > _graphWindow) {
      chartDataCh[idx].removeFirst();
    }
  }

  static Color _lineColor(int idx) {
    if (idx == 1) return Colors.deepOrangeAccent;
    return Colors.blueAccent;
  }

  @override
  void dispose() {
    _bluetoothHandler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          BluetoothIndicator(bluetoothService: _bluetoothHandler),
          BluetoothIndicator(bluetoothService: _bluetoothHandler),
        ],
      ),
      body: Row(
        children: [
          Expanded(
              child: BluetoothDeviceList(bluetoothService: _bluetoothHandler)),
          Checkbox(
            value: _graphFilerAverage,
            onChanged: (bool? newValue) {
              _graphFilerAverage = newValue!;
              setState(() {}); // Update UI layer
            },
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(
                LineChartData(
                  lineBarsData: List.generate(
                      chartDataCh[0].isNotEmpty ? chartDataCh.length : 0,
                      (i) => LineChartBarData(
                            spots: chartDataCh[i].toList(growable: false),
                            dotData: const FlDotData(
                              show: false,
                            ),
                            color: _lineColor(i),
                          ),
                      growable: false),
                  titlesData: const FlTitlesData(
                      topTitles: AxisTitles(), leftTitles: AxisTitles()),
                  minY: 0, // TODO: negative values
                  clipData: const FlClipData.all(),
                ),
                duration: Duration.zero,
                //duration: const Duration(milliseconds: 1000),
                curve: Curves.linear,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _bluetoothHandler.isScanning,
        builder: (context, isScanning, child) {
          return FloatingActionButton(
            onPressed: () {
              unawaited(_bluetoothHandler.toggleScan());
            },
            tooltip: isScanning ? 'Stop scanning' : 'Start scanning',
            child: Icon(isScanning ? Icons.stop : Icons.search),
          );
        },
      ),
    );
  }
}

class _DataTransformer {
  static const int numGraphLines = 2;

  static int _chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1; // No graph line for this chanel
  }

  static void _parseAndAppendDataPacket(Uint8List data,
      void Function(int val, int idx) dataCb, void Function() eodCb) {
    if (data.isEmpty || data.length % 15 != 0) {
      debugPrint('Incorrect buffer size received');
    }

    for (int packetStart = 0; packetStart < data.length; packetStart += 15) {
      assert(packetStart + 15 <= data.length);
      // final status = (data[packetStart + 1] << 8) | data[packetStart];
      // final crc = data[packetStart + 14];
      const int numAdcChan = 4;
      for (int i = 0; i < numAdcChan; ++i) {
        final int baseIndex = packetStart + 2 + i * 3;
        int res = ((data[baseIndex + 2] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex])
            .toSigned(24);
        int idx = _chanToLine(i);
        if (idx >= 0) {
          dataCb(res, idx);
        }
      }
    }
    eodCb();
  }
}

class AvgAdcData {
  AvgAdcData(int numLines)
      : _avg = Float64List(numLines),
        _runningTotal = Float64List(numLines);
  // TODO: this is preliminary implementation
  final Float64List _avg;
  final Float64List _runningTotal;
  int _avgWindow = 256;
  int _count = 0;

  void _add(int val, int idx) {
    _runningTotal[idx] += val;
    _count++;
    if (_count >= _avgWindow * _runningTotal.length) {
      _count = 0;
      for (int i = 0; i < _runningTotal.length; ++i) {
        _avg[i] = _runningTotal[i].toDouble() / _avgWindow;
        _runningTotal[i] = 0;
      }
    }
  }

  double getAvg(int idx) {
    return _avg[idx];
  }

  void setVindow(int w) {
    assert(w > 1);
    _avgWindow = w;
  }
}

class BluetoothDeviceList extends StatelessWidget {
  final BluetoothHandling bluetoothService;

  const BluetoothDeviceList({super.key, required this.bluetoothService});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (bluetoothService.isScanning.value)
          const CircularProgressIndicator(),
        Expanded(
          child: ValueListenableBuilder<List<BleDevice>>(
            valueListenable: bluetoothService.devices,
            builder: (context, devices, _) {
              return ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return ListTile(
                    title: Text(device.name ?? "Unknown Device"),
                    subtitle: Text('Device ID: ${device.deviceId}'),
                    onTap: () =>
                        unawaited(bluetoothService.connectToDevice(device)),
                  );
                },
              );
            },
          ),
        ),
        Flexible(
          // Use Flexible instead of Expanded here to ensure layout stability
          child: ValueListenableBuilder<BleDevice?>(
            valueListenable: bluetoothService.selectedDevice,
            builder: (context, selectedDevice, _) {
              return selectedDevice != null
                  ? BluetoothServiceDetails(bluetoothService: bluetoothService)
                  : SizedBox.shrink();
            },
          ),
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
    return Column(
      children: [
        const Divider(),
        Text(
          'Connected to: ${bluetoothService.selectedDevice.value?.name ?? "Unknown Device"}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Expanded(
          child: ValueListenableBuilder<List<BleService>>(
            valueListenable: bluetoothService.services,
            builder: (context, services, _) {
              if (services.isNotEmpty) {
                return ListView.builder(
                  itemCount: services.length,
                  itemBuilder: (context, index) {
                    final service = services[index];
                    return ListTile(
                      title: Text('Service: ${service.uuid}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: service.characteristics
                            .map((char) => Text('Characteristic: ${char.uuid}'))
                            .toList(),
                      ),
                      onTap: () => bluetoothService.subscribeToService(service),
                    );
                  },
                );
              } else {
                return const Text('No services found for this device.');
              }
            },
          ),
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
    return ValueListenableBuilder<bool>(
      valueListenable: bluetoothService.isScanning,
      builder: (context, isScanning, child) {
        final IconData iconData;
        final Color color;

        // Determine icon based on Bluetooth and scanning states
        if (isScanning) {
          iconData = Icons.bluetooth_searching;
          color = Colors.lightBlue;
        } else {
          switch (bluetoothService.bluetoothState) {
            case AvailabilityState.poweredOn:
              iconData = Icons.bluetooth;
              color = Colors.blueAccent;
              break;
            case AvailabilityState.poweredOff:
              iconData = Icons.bluetooth_disabled;
              color = Colors.blueGrey;
              break;
            case AvailabilityState.unknown:
              iconData = Icons.question_mark;
              color = Colors.yellow;
              break;
            case AvailabilityState.resetting:
              iconData = Icons.question_mark;
              color = Colors.green;
              break;
            case AvailabilityState.unsupported:
              iconData = Icons.stop;
              color = Colors.red;
              break;
            case AvailabilityState.unauthorized:
              iconData = Icons.stop;
              color = Colors.orange;
              break;
            // ignore: unreachable_switch_default
            default:
              iconData = Icons.question_mark;
              color = Colors.grey;
              break;
          }
        }

        return Padding(
          padding: const EdgeInsets.all(8.0),
          child: Icon(iconData, color: color),
        );
      },
    );
  }
}
