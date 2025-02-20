import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:universal_ble/universal_ble.dart'
    show AvailabilityState, BleDevice, BleService;

import 'bt_handling.dart' show BluetoothHandling;

const int numAdcChan = 4;
const int numGraphLines = 2;
const int graphWindow = 200;
const int avgWindow = 256;

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  final String title = 'Graph';

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final BluetoothHandling _bluetoothHandler = BluetoothHandling();
  bool _graphFilerAverage = true;

  final List<Queue<FlSpot>> chartDataCh = List.generate(
    numGraphLines,
    (_) => Queue<FlSpot>(),
    growable: false,
  );

  final AvgAdcData avgAdcData = AvgAdcData();
  int xVal = 0;

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
    _parseAndAppendDataPacket(data);
    setState(() {}); // Update UI layer
  }

  void _parseAndAppendDataPacket(Uint8List data) {
    if (data.isEmpty || data.length % 15 != 0) {
      debugPrint('Incorrect buffer size received');
    }

    for (int packetStart = 0; packetStart < data.length; packetStart += 15) {
      assert(packetStart + 15 <= data.length);
      // final status = (data[packetStart + 1] << 8) | data[packetStart];
      final Int32List channels = Int32List(numAdcChan);
      for (int i = 0; i < channels.length; ++i) {
        int baseIndex = packetStart + 2 + i * 3;
        channels[i] = ((data[baseIndex + 2] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex])
            .toSigned(24);
      }
      // final crc = data[packetStart + 14];

      avgAdcData.add(channels);
      for (int i = 0; i < numGraphLines; ++i) {
        final int adcChan = i + 1;
        chartDataCh[i].add(FlSpot(
            xVal.toDouble(),
            channels[adcChan].toDouble() -
                (_graphFilerAverage ? avgAdcData.getAvg(adcChan) : 0)));
      }
      xVal++;
      if (chartDataCh[0].length > graphWindow) {
        for (int i = 0; i < numGraphLines; ++i) {
          chartDataCh[i].removeFirst();
        }
      }
    }
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
                  lineBarsData: ([
                    LineChartBarData(
                      spots: chartDataCh[0].toList(growable: false),
                      dotData: const FlDotData(
                        show: false,
                      ),
                      color: Colors.blueAccent,
                    ),
                    LineChartBarData(
                      spots: chartDataCh[1].toList(growable: false),
                      dotData: const FlDotData(
                        show: false,
                      ),
                      color: Colors.deepOrangeAccent,
                    ),
                  ]),
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

class AvgAdcData {
  final Float64List avg = Float64List(numAdcChan);
  final Int64List runningTotal = Int64List(numAdcChan);
  int count = avgWindow;

  void add(Int32List val) {
    for (int i = 0; i < numAdcChan; ++i) {
      runningTotal[i] += val[i];
    }
    count--;
    if (count == 0) {
      count = avgWindow;
      for (int i = 0; i < runningTotal.length; ++i) {
        avg[i] = runningTotal[i].toDouble() / avgWindow;
        runningTotal[i] = 0;
      }
    }
  }

  double getAvg(int idx) {
    return avg[idx];
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
