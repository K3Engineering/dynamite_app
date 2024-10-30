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

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  List<BleDevice> _devices = [];
  bool _isScanning = false;
  BleDevice? _selectedDevice;
  List<BleService> _services = [];
  AvailabilityState _bluetoothState = AvailabilityState.unknown;

  @override
  void initState() {
    super.initState();

    // TODO this doesn't work on web
    UniversalBle.enableBluetooth();

    _updateBluetoothState();
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
  }

  Future<void> _updateBluetoothState() async {
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    setState(() {});
  }

  void _onScanResult(BleDevice device) {
    setState(() {
      if (!_devices.contains(device)) {
        _devices.add(device);
      }
    });
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    setState(() {
      _bluetoothState = state;
    });
  }

  void _onPairingStateChange(deviceId, isPaired){
    print('pairing state change');
    print(deviceId);
    print(isPaired);
  }


  Future<void> _startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth is not powered on!')),
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _devices.clear();
    });
    UniversalBle.startScan(
      platformConfig: PlatformConfig(
          web: WebOptions(
            optionalServices: [
                BT_SERVICE_ID,
              BT_CHARACTERISTIC_ID,
              BT_S2,
              BT_S3,]
          )
        )
        // scanFilter: ScanFilter(
        //   // Needs to be passed for web, can be empty for the rest
        //   withServices: [
        //     BT_SERVICE_ID,
        //     BT_CHARACTERISTIC_ID,
        //     BT_S2,
        //     BT_S3,
        //     ],
        // )
    );
  }

  void _stopScan() {
    UniversalBle.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  Future<void> _connectToDevice(BleDevice device) async {
    try {
      await UniversalBle.connect(device.deviceId);
      List<BleService> services = await UniversalBle.discoverServices(device.deviceId);
      setState(() {
        _selectedDevice = device;
        _services = services;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to connect to ${device.name ?? "Unknown Device"} due to error: $e')),
      );
    }
  }

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          BluetoothIndicator(bluetoothState: _bluetoothState),
          IconButton(
            icon: const Icon(Icons.abc),
            tooltip: 'ABC Icon',
            onPressed: () {},
          ), //IconButton
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isScanning) const CircularProgressIndicator(),
            Expanded(
              child: ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  return ListTile(
                    title: Text(device.name ?? "Unknown Device"),
                    subtitle: Text('Device ID: ${device.deviceId}'),
                    onTap: () => _connectToDevice(device),
                  );
                },
              ),
            ),
            if (_selectedDevice != null) ...[
              const Divider(),
              Text(
                'Connected to: ${_selectedDevice?.name ?? "Unknown Device"}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _services.isNotEmpty
                    ? ListView.builder(
                        itemCount: _services.length,
                        itemBuilder: (context, index) {
                          final service = _services[index];
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
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isScanning ? _stopScan : _startScan,
        tooltip: 'Toggle scanning',
        child: Icon(_isScanning ? Icons.stop : Icons.add),
      ),
    );
  }
}

class BluetoothIndicator extends StatelessWidget {
  final AvailabilityState bluetoothState;

  const BluetoothIndicator({Key? key, required this.bluetoothState}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    IconData iconData;
    Color color;

    switch (bluetoothState) {
      case AvailabilityState.poweredOn:
        iconData = Icons.bluetooth;
        color = Colors.blue;
        break;
      case AvailabilityState.poweredOff:
        iconData = Icons.bluetooth_disabled;
        color = Colors.red;
        break;
      default:
        iconData = Icons.bluetooth_searching;
        color = Colors.grey;
        break;
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Icon(iconData, color: color),
    );
  }
}