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

  final List<List<int>> decodedChannels = [];
  final List<int> decodedStatus = [];
  final List<int> decodedCRC = [];

  List<FlSpot> chartDataCh1 = [FlSpot(0, 0)];
  List<FlSpot> chartDataCh2 = [FlSpot(0, 0)];

  @override
  void initState() {
    super.initState();

    _bluetoothHandler.initializeBluetooth();
    _bluetoothHandler.onNewDataCallback = processReceivedData;
  }

  void processReceivedData(Uint8List data) {
    _parseAndAppendDataPacket(data);
    setState(() {
      _updateChartData(); // Update UI layer
    });
  }

  void _parseAndAppendDataPacket(Uint8List data) {
    if (data.isEmpty || data.length % 15 != 0) {
      debugPrint('Incorrect buffer size received');
    }

    for (int packetStart = 0; packetStart < data.length; packetStart += 15) {
      assert(packetStart + 14 < data.length);
      final status = (data[packetStart + 1] << 8) | data[packetStart];
      final channels = List.generate(4, (i) {
        int baseIndex = packetStart + 2 + i * 3;
        return ((data[baseIndex + 2] << 16) |
                (data[baseIndex + 1] << 8) |
                data[baseIndex])
            .toSigned(24);
      });
      final crc = data[packetStart + 14];

      decodedChannels.add(channels);
      decodedStatus.add(status);
      decodedCRC.add(crc);
    }
  }

  void _updateChartData() {
    const int window = 6400;
    final int start = (decodedChannels.length <= window)
        ? 0
        : decodedChannels.length - window;

    chartDataCh1 = List.generate(
      decodedChannels.length - start,
      (i) => FlSpot(
        (i + start).toDouble(),
        decodedChannels[i + start][2].toDouble(),
      ),
    );

    chartDataCh2 = List.generate(
      decodedChannels.length - start,
      (i) => FlSpot(
        (i + start).toDouble(),
        decodedChannels[i + start][1].toDouble(),
      ),
    );
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
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh BT Icon',
            onPressed: _bluetoothHandler.toggleScan,
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
              child: BluetoothDeviceList(bluetoothService: _bluetoothHandler)),
          Expanded(
              child: LineChart(
            LineChartData(
              lineBarsData: ([
                LineChartBarData(
                    spots: chartDataCh1,
                    dotData: FlDotData(
                      show: false,
                    )),
                LineChartBarData(
                    spots: chartDataCh2,
                    dotData: FlDotData(
                      show: false,
                    ))
              ]),
              minY:
                  0, // TODO make this into min(data, 0), as negative values go outside the chart
            ),
            //duration: const Duration(milliseconds: 1000),
          )),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _bluetoothHandler.isScanning,
        builder: (context, isScanning, child) {
          return FloatingActionButton(
            onPressed: _bluetoothHandler.toggleScan,
            tooltip: isScanning ? 'Stop scanning' : 'Start scanning',
            child: Icon(isScanning ? Icons.stop : Icons.search),
          );
        },
      ),
    );
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
                    onTap: () => bluetoothService.connectToDevice(device),
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
