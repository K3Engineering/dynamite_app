import 'package:flutter/foundation.dart';

import '../analysis/plate_series.dart';
import '../services/data_hub.dart';

/// The data side of a test run: the live plate's sample storage, its tare
/// controls, and a repaint signal. Production wraps [DataHub]; tests feed
/// synthetic corner forces with no calibration involved.
abstract interface class PlateSource {
  int get totalSamples;
  int get oldestSample;

  /// A plate reader in kgf, or null while any corner cannot be read (no board
  /// map / load cell).
  PlateReader? read();

  Listenable get changes;

  bool get taring;
  int get tareVersion;
  void requestTare();
}

/// [PlateSource] over the live hub. [read] rebuilds the reader each call so a
/// calibration or cell edit is picked up immediately.
class DataHubPlateSource implements PlateSource {
  DataHubPlateSource(this._hub);

  final DataHub _hub;

  @override
  int get totalSamples => _hub.totalSamples;

  @override
  int get oldestSample => _hub.oldestSample;

  @override
  PlateReader? read() => PlateReader.tryForData(_hub);

  @override
  Listenable get changes => _hub;

  @override
  bool get taring => _hub.taring;

  @override
  int get tareVersion => _hub.tareVersion;

  @override
  void requestTare() => _hub.requestTare();
}
