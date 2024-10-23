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
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
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
      UniversalBle.startScan();
    } else {
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
                    subtitle: Text(device.deviceId),
                  );
                },
              ),
            ),
            ElevatedButton(
              onPressed: _isScanning ? _stopScan : _startScan,
              child: Text(_isScanning ? 'Stop Scan' : 'Start Scan'),
            ),
          ],
        ),
      ),
    );
  }
}
