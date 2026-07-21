import 'package:flutter/foundation.dart';

/// High-frequency diagnostic logging (packet-rate paths). Stripped in
/// release/profile builds, where per-packet [debugPrint] would throttle the
/// band and spam end-user consoles. The message is built lazily (only in
/// debug), so call sites pay nothing in release — wrap interpolation in the
/// closure: `logTrace(() => 'lost $diff samples')`.
void logTrace(String Function() message) {
  if (kDebugMode) debugPrint(message());
}
