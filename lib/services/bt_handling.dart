import 'dart:async';
import 'dart:typed_data';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import 'bt_device_config.dart';
import '../models/force_unit.dart';
// ignore: unused_import
import 'mockble.dart';
import 'data_isolate.dart';

class BluetoothHandling extends ChangeNotifier {
  AvailabilityState _bluetoothState = AvailabilityState.unknown;
  AvailabilityState get bluetoothState => _bluetoothState;

  final List<BleDevice> _devices = [];
  List<BleDevice> get devices => _devices;

  final List<BleService> _services = [];
  List<BleService> get services => _services;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  String _selectedDeviceId = '';
  String get selectedDeviceId => _selectedDeviceId;

  /// Name of the currently connected device.
  String _connectedDeviceName = '';
  String get connectedDeviceName =>
      _connectedDeviceName.isEmpty ? _selectedDeviceId : _connectedDeviceName;

  bool _isSubscribed = false;
  bool get isSubscribed => _isSubscribed;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  final DataHub dataHub = DataHub();

  BluetoothHandling() {
    if (useMockBt) {
      UniversalBle.setInstance(MockBlePlatform.instance);
    }
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onAvailabilityChange = _onBluetoothAvailabilityChanged;
    UniversalBle.onConnectionChange = _onConnectionChange;
    UniversalBle.onPairingStateChange = _onPairingStateChange;
    UniversalBle.onValueChange = _processReceivedData;

    unawaited(_updateBluetoothState());
  }

  void stopProcessing() {
    UniversalBle.onValueChange = null;
  }

  Future<void> _updateBluetoothState() async {
    if (!kIsWeb) {
      await UniversalBle.enableBluetooth();
    }
    _bluetoothState = await UniversalBle.getBluetoothAvailabilityState();
    _notifyStateChanged();
  }

  void _onScanResult(BleDevice newDevice) {
    // Keep all discovered devices (replace if same ID seen again with better RSSI).
    final existingIdx = _devices.indexWhere(
      (d) => d.deviceId == newDevice.deviceId,
    );
    if (existingIdx >= 0) {
      if (newDevice.rssi != null &&
          (_devices[existingIdx].rssi == null ||
              newDevice.rssi! > _devices[existingIdx].rssi!)) {
        _devices[existingIdx] = newDevice;
      }
    } else {
      _devices.add(newDevice);
    }
    _notifyStateChanged();
  }

  void _onBluetoothAvailabilityChanged(AvailabilityState state) {
    _bluetoothState = state;
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    _isScanning = false;
    _notifyStateChanged();
  }

  Future<void> _startScan() async {
    if (_bluetoothState != AvailabilityState.poweredOn) {
      return;
    }
    await disconnectSelectedDevice();
    _devices.clear();
    _services.clear();
    if (_isSubscribed) {
      return;
    }
    _isScanning = true;
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [btServiceId]),
      platformConfig: PlatformConfig(
        web: WebOptions(optionalServices: [btServiceId]),
      ),
    );
    _notifyStateChanged();
  }

  Future<void> toggleScan() async {
    if (_isScanning) {
      await _stopScan();
    } else {
      await _startScan();
    }
  }

  void toggleSession() {
    assert(_selectedDeviceId.isNotEmpty);
    if (!_sessionInProgress) {
      // Starting a recording: mark the current buffer position.
      dataHub.setRecordingStart();
    }
    _sessionInProgress = !_sessionInProgress;
    _notifyStateChanged();
  }

  void stopSession() {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      _notifyStateChanged();
    }
  }

  void _onPairingStateChange(String deviceId, bool isPaired) {
    debugPrint('isPaired $deviceId, $isPaired');
  }

  void _onConnectionChange(
    String deviceId,
    bool isConnected,
    String? err,
  ) async {
    debugPrint(
      'isConnected $deviceId, $isConnected ${(err == null) ? '' : err}',
    );

    if (isConnected) {
      _selectedDeviceId = deviceId;

      // Store the device name
      final device = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
      _connectedDeviceName = device?.name ?? deviceId;

      if (!kIsWeb) {
        debugPrint('Requested MTU change');
        final int mtu = await UniversalBle.requestMtu(deviceId, 247);
        debugPrint('MTU set to: $mtu');
      }
      _services.addAll(await UniversalBle.discoverServices(deviceId));
      for (final srv in _services) {
        if (srv.uuid == btServiceId) {
          await subscribeToAdcFeed(srv);
          break;
        }
      }
    } else {
      _isSubscribed = false;
      _selectedDeviceId = '';
      _connectedDeviceName = '';
      _services.clear();
      _sessionInProgress = false;
    }
    _notifyStateChanged();
  }

  Future<void> connectToDevice(String deviceId) async {
    if (_isScanning) {
      await _stopScan();
    }
    if (_selectedDeviceId.isEmpty) {
      await UniversalBle.connect(deviceId);
    }
  }

  Future<void> disconnectSelectedDevice() async {
    if (_selectedDeviceId.isNotEmpty) {
      await UniversalBle.disconnect(_selectedDeviceId);
      await UniversalBle.getBluetoothAvailabilityState(); // fix for a bug in UBle
    }
  }

  Future<void> subscribeToAdcFeed(BleService service) async {
    if (_selectedDeviceId.isEmpty) {
      return;
    }
    for (final characteristic in service.characteristics) {
      if ((characteristic.uuid == btChrAdcFeedId) &&
          characteristic.properties.contains(CharacteristicProperty.notify)) {
        dataHub._updateCalibration(
          await UniversalBle.read(
            _selectedDeviceId,
            service.uuid,
            btChrCalibration,
          ),
        );
        await UniversalBle.subscribeNotifications(
          _selectedDeviceId,
          service.uuid,
          characteristic.uuid,
        );
        _isSubscribed = true;
        _notifyStateChanged();
        return;
      }
    }
  }

  void _notifyStateChanged() {
    notifyListeners();
  }

  void _processReceivedData(String _, String _, Uint8List data, int? _) {
    // Always stream data to the DataHub for live display.
    final canContinue = dataHub._parseDataPacket(data);
    if (!canContinue) {
      stopSession();
    }
  }
}

class DataHub extends ChangeNotifier {
  static const int numGraphLines = 2;
  static const int numAdcChannels = 4;
  static const double _defaultSlope = 0.0001117587;
  static const int samplesPerSec = 1000;
  static const int _maxDataDurationSeconds = 60 * 10;

  Float64List tare = Float64List(numGraphLines);
  Int32List rawMax = Int32List(numGraphLines);
  Int32List _currentRaw = Int32List(numGraphLines);

  int rawSz = 0;
  int _recordingStartIdx = 0;
  int get recordingStartIdx => _recordingStartIdx;

  DeviceCalibration deviceCalibration = DeviceCalibration(0, _defaultSlope);

  // Isolate stuff
  SendPort? _isolateSendPort;
  late final ReceivePort _receivePort;

  // Render requests mapping to track Future completors for slices, etc.
  int _lastRenderWidth = -1;
  final Map<int, Float32List> renderData = {};

  DataHub() {
    _initIsolate();
  }

  Future<void> _initIsolate() async {
    _receivePort = ReceivePort();
    await Isolate.spawn(dataIsolateEntryPoint, _receivePort.sendPort);

    _receivePort.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        _isolateSendPort!.send(
          InitRequest(samplesPerSec, _maxDataDurationSeconds, numAdcChannels),
        );
      } else if (message is StatsUpdateResponse) {
        rawSz = message.rawSz;
        _currentRaw = message.currentRaw;
        rawMax = message.peakRaw;
        tare = message.tare;
        _recordingStartIdx = message.recordingStartIdx;
        notifyListeners();
        _autoRequestRender();
      } else if (message is RenderResultResponse) {
        renderData[message.lineIdx] = message.minMaxData
            .materialize()
            .asFloat32List();
        notifyListeners();
      } else if (message is SliceResultResponse) {
        // Find matching completor. We can store one global completor for simplicity.
        _sliceCompleter?.complete(message.channelsData);
        _sliceCompleter = null;
      }
    });
  }

  void _autoRequestRender() {
    if (_lastRenderWidth > 0 && _isolateSendPort != null) {
      int endTimeMs = (rawSz * 1000) ~/ samplesPerSec;
      // Request full available range
      _isolateSendPort!.send(
        RenderRequest(
          startTimeMs: 0,
          endTimeMs: endTimeMs,
          pixelWidth: _lastRenderWidth,
          replyPort: _receivePort.sendPort,
        ),
      );
    }
  }

  void requestRenderWidth(int width) {
    if (_lastRenderWidth != width) {
      _lastRenderWidth = width;
      _autoRequestRender();
    }
  }

  Completer<List<Int32List>>? _sliceCompleter;

  Future<List<Int32List>> fetchSlice(int startIdx, int endIdx) {
    if (_isolateSendPort == null) return Future.value([]);
    _sliceCompleter = Completer<List<Int32List>>();
    _isolateSendPort!.send(
      FetchSliceRequest(
        startIdx: startIdx,
        endIdx: endIdx,
        replyPort: _receivePort.sendPort,
      ),
    );
    return _sliceCompleter!.future;
  }

  void clear() {
    // Usually restarting connection
    _isolateSendPort?.send(
      InitRequest(samplesPerSec, _maxDataDurationSeconds, numAdcChannels),
    );
  }

  void requestTare() {
    _isolateSendPort?.send(TareRequest());
  }

  void setRecordingStart() {
    _isolateSendPort?.send(SetSessionRecordingStartRequest());
  }

  static int chanToLine(int chan) {
    if (chan == 1) return 0;
    if (chan == 2) return 1;
    return -1;
  }

  double currentForce(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0) return 0;
    final rawTared = _currentRaw[lineIdx] - tare[lineIdx];
    final kgf = rawTared * deviceCalibration.slope;
    return unit.fromKgf(kgf);
  }

  double peakForce(int adcChannel, ForceUnit unit) {
    final lineIdx = chanToLine(adcChannel);
    if (lineIdx < 0) return 0;
    final rawTared = rawMax[lineIdx] - tare[lineIdx];
    final kgf = rawTared * deviceCalibration.slope;
    return unit.fromKgf(kgf);
  }

  void _updateCalibration(Uint8List data) {
    deviceCalibration = DeviceCalibration(0, _defaultSlope);
  }

  bool _parseDataPacket(Uint8List data) {
    if (_isolateSendPort == null) return true;
    _isolateSendPort!.send(BlePacketRequest(data));
    return true; // We can always accept data
  }
}

class DeviceCalibration {
  DeviceCalibration(this.offset, this.slope);
  final int offset;
  final double slope;
}
