import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'dart:typed_data';
//import 'package:convert/convert.dart';
import 'package:fl_chart/fl_chart.dart';
import 'mockble.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;

// const BT_DEVICE_UUID = "E4:B0:63:81:5B:19";
const BT_GATT_ID = "a659ee73-460b-45d5-8e63-ab6bf0825942";
const BT_SERVICE_ID = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
const BT_CHARACTERISTIC_ID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const BT_S2 = "00001800-0000-1000-8000-00805f9b34fb";
const BT_S3 = "00001801-0000-1000-8000-00805f9b34fb";

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bluetooth Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final BluetoothHandling _bluetoothHandler = BluetoothHandling();
  final List<int> deviceData = [];
  final List<FlSpot> chartData = [FlSpot(0, 0)];

  @override
  void initState() {
    super.initState();

    _bluetoothHandler.initializeBluetooth();

    // Listen to receivedData changes
    _bluetoothHandler.receivedData.addListener(() {
      processReceivedData(_bluetoothHandler.receivedData.value);
    });
  }

  void processReceivedData(Uint8List? value) {
    if ((value == null) || value.isEmpty || (value.length % 3 != 0)) {
      return;
    }
    // Decode 24-bit values into integers
    for (int i = 0; i < value.length; i += 3) {
      int intValue = (value[i + 2] << 16) | (value[i + 1] << 8) | value[i];
      deviceData.add(intValue.toSigned(24));
    }

    // Update adcReadings and refresh the chart
    setState(() {
      chartData.clear();
      const int window = 64;
      int start =
          (deviceData.length <= window) ? 0 : deviceData.length - window;
      for (int i = start; i < deviceData.length; i++) {
        chartData.add(FlSpot(i.toDouble(), deviceData[i].toDouble()));
      }
    });
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
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
              child: FractionallySizedBox(
                  widthFactor: 0.98,
                  heightFactor: 0.97,
                  alignment: Alignment.bottomLeft,
                  child: LineChart(
                    LineChartData(
                      lineBarsData: ([LineChartBarData(spots: chartData)]),
                      titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false))),
                      //minX: 0,
                      minY: 0,
                    ),
                    duration: const Duration(milliseconds: 200),
                  ))),
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

// class BluetoothDevice {
//   final BluetoothHandling _bluetoothHanlder = BluetoothHandling();
//   // const BT_DEVICE_UUID = "E4:B0:63:81:5B:19";
//   static const BT_GATT_ID = "a659ee73-460b-45d5-8e63-ab6bf0825942";
//   static const BT_SERVICE_ID = "e331016b-6618-4f8f-8997-1a2c7c9e5fa3";
//   static const BT_CHARACTERISTIC_ID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
//   static const BT_S2 = "00001800-0000-1000-8000-00805f9b34fb";
//   static const BT_S3 = "00001801-0000-1000-8000-00805f9b34fb";

//   void init() {
//     _bluetoothHanlder.initializeBluetooth();
//   }
// }

class ListNotifier<T> extends ChangeNotifier
    implements ValueListenable<List<T>> {
  ListNotifier() : _value = [];
  final List<T> _value;
  @override
  List<T> get value => List.unmodifiable(_value);

  void assign(Iterable<T> it) {
    _value.clear();
    _value.addAll(it);
    notifyListeners();
  }

  void append(T item) {
    _value.add(item);
    notifyListeners();
  }

  void clear() {
    _value.clear();
    notifyListeners();
  }
}

class BluetoothHandling {
  AvailabilityState bluetoothState = AvailabilityState.unknown;
  ListNotifier<BleDevice> devices = ListNotifier<BleDevice>();
  ValueNotifier<bool> isScanning = ValueNotifier<bool>(false);
  ValueNotifier<BleDevice?> selectedDevice = ValueNotifier<BleDevice?>(null);
  ListNotifier<BleService> services = ListNotifier<BleService>();
  ValueNotifier<Uint8List?> receivedData = ValueNotifier<Uint8List?>(null);

  void initializeBluetooth() {
    UniversalBle.setInstance(MockBlePlatform.instance);

    _updateBluetoothState();

    if (!kIsWeb) {
      UniversalBle.enableBluetooth(); // this isn't implemented on web
    }

    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
  }

  Future<void> _updateBluetoothState() async {
    bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
  }

  void _onScanResult(BleDevice device) {
    for (var deviceListDevice in devices.value) {
      if (deviceListDevice.deviceId == device.deviceId) {
        if (deviceListDevice.name == device.name) {
          return;
        }
      }
    }
    devices.append(device);
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    bluetoothState = state;
  }

  void stopScan() async {
    UniversalBle.stopScan();
    isScanning.value = false;
  }

  void startScan() async {
    if (bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    devices.clear();
    services.clear();
    isScanning.value = true;
    await UniversalBle.startScan(
      platformConfig: PlatformConfig(
        web: WebOptions(optionalServices: [
          BT_SERVICE_ID,
          BT_CHARACTERISTIC_ID,
          BT_S2,
          BT_S3
        ]),
      ),
    );
  }

  void toggleScan() async {
    if (isScanning.value) {
      stopScan();
    } else {
      startScan();
    }
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
    // _addLog("PairingStateChange - isPaired", isPaired);
  }

  Future<void> connectToDevice(BleDevice device) async {
    if (isScanning.value) {
      stopScan();
    }
    try {
      await UniversalBle.connect(device.deviceId);
      services.assign(await UniversalBle.discoverServices(device.deviceId));
      selectedDevice.value = device;
    } catch (e) {
      // Error handling can be implemented here
    }
  }

  void dispose() {
    UniversalBle.onScanResult = null;
    UniversalBle.onAvailabilityChange = null;
  }

  void subscribeToService(BleService service) async {
    final deviceId = selectedDevice.value?.deviceId;
    if (deviceId == null) return;

    // TODO can only subscribe once, otherwise I get "DartError: Exception: Already listening to this characteristic"
    for (var characteristic in service.characteristics) {
      if ((characteristic.uuid == BT_CHARACTERISTIC_ID) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        UniversalBle.onValueChange =
            (String deviceId, String characteristicId, Uint8List value) {
          // debugPrint('onValueChange $deviceId, $characteristicId, ${hex.encode(value)}');
          // TODO bug: if the new value is identical then there's no update
          receivedData.value = null;
          receivedData.value = value; // Notify the UI layer of new data
        };

        await UniversalBle.setNotifiable(deviceId, service.uuid,
            characteristic.uuid, BleInputProperty.notification);

        return;
      }
    }
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
        IconData iconData;
        Color color;

        // Determine icon based on Bluetooth and scanning states
        if (isScanning) {
          iconData = Icons.bluetooth_searching;
          color = Colors.blueAccent;
        } else {
          switch (bluetoothService.bluetoothState) {
            case AvailabilityState.poweredOn:
              iconData = Icons.bluetooth;
              color = Colors.blue;
              break;
            case AvailabilityState.poweredOff:
              iconData = Icons.bluetooth_disabled;
              color = Colors.red;
              break;
            case AvailabilityState.unknown:
              iconData = Icons.question_mark;
              color = Colors.red;
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
              color = Colors.blue;
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
