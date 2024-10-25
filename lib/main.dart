import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

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

  @override
  void initState() {
    super.initState();

    // Set up the scan result handler
    UniversalBle.onScanResult = (BleDevice device) {
      setState(() {
        // Avoid duplicates in the list
        if (!_devices.contains(device)) {
          _devices.add(device);
        }
      });
    };
  }


  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _devices.clear(); // Clear list before starting scan
    });

    AvailabilityState state = await UniversalBle.getBluetoothAvailabilityState();
    if (state == AvailabilityState.poweredOn) {
      UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: ["e331016b-6618-4f8f-8997-1a2c7c9e5fa3"],
        )
      );
    } else {
      if (!mounted) return;

      // Handle the case where Bluetooth is not available or not powered on
      setState(() {
        _isScanning = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth is not powered on!')),
      );
    }
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

      // Discover services
      List<BleService> services = await UniversalBle.discoverServices(device.deviceId);

      setState(() {
        _selectedDevice = device;
        _services = services;
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to connect to ${device.name ?? "Unknown Device"} due to error $e')),
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
                    subtitle: Text('device ID: ${device.deviceId}'),
                    onTap: () => _connectToDevice(device), // Connect when tapped
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
        child: Icon( _isScanning ? Icons.stop : Icons.add ),
      ),
    );
  }
}