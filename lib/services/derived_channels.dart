import 'package:flutter/foundation.dart';

import '../models/derived_channel.dart';

/// The rig's math-channel profile, owned app-side per the branch's scope:
/// in-memory, defaulting to the force-plate profile over corner order
/// [0,1,2,3] (the historical behavior). Consumers are wired from `main`.
///
/// TODO(rig-config): persist per device in the device KVS (the load-cell
/// slots' neighbor), with the profile arriving via [RigState]'s flash
/// document like the slots do. Sessions snapshot the profile at record
/// start, so review no longer depends on the CURRENT config.
class DerivedChannels extends ChangeNotifier {
  DerivedChannels._();

  static final DerivedChannels instance = DerivedChannels._();

  /// The configured profile; [MathProfile.specs] is the derived-channel set
  /// in id order (id = kAdcChannelCount + index). Availability (all members
  /// calibrated) is decided per source.
  MathProfile profile = MathProfile.forcePlate(const [0, 1, 2, 3]);

  void setProfile(MathProfile next) {
    profile = next;
    notifyListeners();
  }
}
