import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

enum DeviceState { None, Interrogating, Available, Irrelevant }

enum ConnectionState { Disconnected, Connecting, Connected }

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
    return MaterialApp(      title: 'Bluetooth Demo',
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
  final BluetoothService _bluetoothService = BluetoothService();


  @override
  void initState() {
    super.initState();

    _bluetoothService.initializeBluetooth(context);
  }

  @override
  void dispose() {
    _bluetoothService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          BluetoothIndicator(bluetoothService: _bluetoothService),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh BT Icon',
            onPressed: _bluetoothService.toggleScan,
          ),
        ],
      ),
      body: BluetoothDeviceList(bluetoothService: _bluetoothService),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _bluetoothService.isScanning,
        builder: (context, isScanning, child) {
          return FloatingActionButton(
            onPressed: _bluetoothService.toggleScan,
            tooltip: isScanning ? 'Stop scanning' : 'Start scanning',
            child: Icon(isScanning ? Icons.stop : Icons.search),
          );
        },
      ),
    );
  }
}

class BluetoothService {
  AvailabilityState bluetoothState = AvailabilityState.unknown;
  List<BleDevice> devices = [];
  ValueNotifier<bool> isScanning = ValueNotifier<bool>(false);
  BleDevice? selectedDevice;
  List<BleService> services = [];

  void initializeBluetooth(BuildContext context) {
    UniversalBle.enableBluetooth(); // TODO this doesn't work on web
    _updateBluetoothState();
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
  }

  Future<void> _updateBluetoothState() async {
    bluetoothState = await UniversalBle.getBluetoothAvailabilityState(); // TODO UnimplementedError
  }

  void _onScanResult(BleDevice device) {
    if (!devices.contains(device)) {
      devices.add(device);
    }
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    bluetoothState = state;
  }

  void stopScan() async {
    UniversalBle.stopScan();
    isScanning.value = false;
  }

  void startScan() async {
      if (bluetoothState == AvailabilityState.poweredOn) {
        devices.clear();
        isScanning.value = true;
        await UniversalBle.startScan(
          platformConfig: PlatformConfig(
            web: WebOptions(optionalServices: [BT_SERVICE_ID, BT_CHARACTERISTIC_ID, BT_S2, BT_S3]),
          ),
        // scanFilter: ScanFilter(
        //           // Needs to be passed for web, can be empty for the rest
        //           withServices: [
        //             BT_SERVICE_ID,
        //             BT_CHARACTERISTIC_ID,
        //             BT_S2,
        //             BT_S3,
        //             ],
        //         )
        );

        isScanning.value = false;
      }
  }

  void toggleScan() async {
    if (isScanning.value) {
      stopScan();
    } else {
      startScan();
    }
  }

  void _onPairingStateChange(deviceId, isPaired){
    print('pairing state change');
    print(deviceId);
    print(isPaired);
  }

  Future<void> connectToDevice(BleDevice device) async {
    try {
      await UniversalBle.connect(device.deviceId);
      services = await UniversalBle.discoverServices(device.deviceId);
      selectedDevice = device;
    } catch (e) {
      // Error handling can be implemented here
    }
  }

  void dispose() {
    UniversalBle.onScanResult = null;
    UniversalBle.onAvailabilityChange = null;
  }
}

class BluetoothDeviceList extends StatelessWidget {
  final BluetoothService bluetoothService;

  const BluetoothDeviceList({Key? key, required this.bluetoothService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (bluetoothService.isScanning.value) const CircularProgressIndicator(),
        Expanded(
          child: ListView.builder(
            itemCount: bluetoothService.devices.length,
            itemBuilder: (context, index) {
              final device = bluetoothService.devices[index];
              return ListTile(
                title: Text(device.name ?? "Unknown Device"),
                subtitle: Text('Device ID: ${device.deviceId}'),
                onTap: () => bluetoothService.connectToDevice(device),
              );
            },
          ),
        ),
        if (bluetoothService.selectedDevice != null)
          BluetoothServiceDetails(bluetoothService: bluetoothService),
      ],
    );
  }
}

class BluetoothServiceDetails extends StatelessWidget {
  final BluetoothService bluetoothService;

  const BluetoothServiceDetails({Key? key, required this.bluetoothService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(),
        Text(
          'Connected to: ${bluetoothService.selectedDevice?.name ?? "Unknown Device"}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Expanded(
          child: bluetoothService.services.isNotEmpty
              ? ListView.builder(
                  itemCount: bluetoothService.services.length,
                  itemBuilder: (context, index) {
                    final service = bluetoothService.services[index];
                    return ListTile(
                      title: Text('Service: ${service.uuid}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: service.characteristics
                            .map((char) => Text('Characteristic: ${char.uuid}'))
                            .toList(),
                      ),
                    );
                  },
                )
              : const Text('No services found for this device.'),
        ),
      ],
    );
  }
}



class BluetoothIndicator extends StatelessWidget {
  final BluetoothService bluetoothService;

  const BluetoothIndicator({Key? key, required this.bluetoothService}) : super(key: key);

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