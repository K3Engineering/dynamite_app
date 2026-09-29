import 'package:flutter/foundation.dart';

import '../models/derived_channel.dart';

/// The rig's derived-channel set (see `derived_channel.dart`), owned
/// app-side per the branch's scope: in-memory, defaulting to the force
/// plate basis over corner order [0,1,2,3].
///
/// TODO(rig-config): persist per device (app profile now, device KVS
/// later), and move corner assignment here from a fixed default — sessions
/// replay with the CURRENT config, so a session recorded with a differently
/// wired plate reviews mirrored until then.
class DerivedChannels extends ChangeNotifier {
  DerivedChannels._();

  static final DerivedChannels instance = DerivedChannels._();

  /// The configured derived channels in id order (id = kAdcChannelCount +
  /// index). Availability (all members calibrated) is decided per source.
  List<DerivedChannelSpec> channels = forcePlateChannels(const [0, 1, 2, 3]);

  void setChannels(List<DerivedChannelSpec> next) {
    channels = next;
    notifyListeners();
  }
}
