import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/feed_health.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import 'feed_health_text.dart';
import 'status_colors.dart';

/// The shared 1 Hz feed-health derivation (see [deriveFeedHealth]), one
/// owner for every surface that wants the live classification — the Devices
/// row's chip ([FeedHealthIndicator]) and the Live tab's banner/stats.
/// [builder] receives the live `ValueListenable<FeedHealth?>`: null when the
/// link is not streaming (no live trace to assess), changing edge-only.
///
/// The ticker (not hub notifications) drives recompute: a silent feed
/// produces no packets, so nothing else would refresh the classification.
class FeedHealthScope extends StatefulWidget {
  const FeedHealthScope({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    ValueListenable<FeedHealth?> health,
  )
  builder;

  @override
  State<FeedHealthScope> createState() => _FeedHealthScopeState();
}

class _FeedHealthScopeState extends State<FeedHealthScope> {
  final ValueNotifier<FeedHealth?> _health = ValueNotifier(null);

  /// App-lifetime singletons, captured (identity-guarded) in
  /// [didChangeDependencies] for listener registration only. Read on ticks,
  /// never watched: the hub notifies per decoded packet.
  DataHub? _hub;
  BleLinkManager? _link;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _link?.removeListener(_onLinkChanged);
      _hub = hub;
      final link = context.read<BleLinkManager>();
      _link = link;
      link.addListener(_onLinkChanged);
    }
  }

  /// Start/stop the ticker on streaming edges. The link manager notifies for
  /// many reasons (RSSI polls included); the edge guard keeps this a no-op
  /// unless streaming actually flipped.
  void _onLinkChanged() {
    final streaming = _link!.isStreaming;
    if (streaming == (_timer != null)) return;
    if (streaming) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
      _health.value = null;
    }
  }

  void _tick() {
    final hub = _hub!;
    final health = deriveFeedHealth(
      streaming: true,
      totalSamples: hub.totalSamples,
      lastDataAt: hub.lastDataAt,
      lastMalformedPacketAt: hub.lastMalformedPacketAt,
      streamStartedAt: hub.streamStartedAt,
    );
    if (health != _health.value) _health.value = health;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _link?.removeListener(_onLinkChanged);
    _health.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _health);
}

/// The one-line feed-health readout ("Packets malformed…", "No data from
/// device", "Stream stopped") the Devices tab renders under the connected
/// row's subtitle. Renders nothing while the feed is healthy or the link
/// isn't streaming.
class FeedHealthIndicator extends StatelessWidget {
  const FeedHealthIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return FeedHealthScope(
      builder: (context, health) => ValueListenableBuilder<FeedHealth?>(
        valueListenable: health,
        builder: (context, health, _) {
          final label = health?.shortLabel;
          if (label == null) return const SizedBox.shrink();
          final color = Theme.of(
            context,
          ).extension<StatusColors>()!.onConnectedWarning;
          return Row(
            children: [
              Icon(Icons.error_outline, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: color),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
