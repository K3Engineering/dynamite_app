import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../benchmark/bench_controller.dart';
import '../benchmark/bench_spec.dart';
import '../services/database.dart';

/// Temporary tab on temp_test: drives the storage benchmark (probe + sweeps)
/// and presents results as a running CSV in a monospace log so rows can be
/// copied straight off the phone browser.
class BenchTab extends StatefulWidget {
  const BenchTab({super.key});

  @override
  State<BenchTab> createState() => _BenchTabState();
}

class _BenchTabState extends State<BenchTab> {
  BenchController? _controller;
  StreamSubscription<String>? _lineSub;

  Workload _workload = Workload.upper;
  final _steadySecField = TextEditingController(text: '10');
  bool _opfs = true;
  bool _idb = true;
  bool _drift = true;
  bool _idbDefaultDurability = false;
  bool _blast = true;
  bool _busy = false;

  final _logField = TextEditingController();
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      final controller = BenchController(db: AppDatabase.instance);
      _controller = controller;
      _lineSub = controller.lines.listen(_appendLine);
      unawaited(() async {
        try {
          await controller.probe();
        } catch (e) {
          _appendLine('ERROR: $e');
        }
      }());
    }
  }

  @override
  void dispose() {
    unawaited(_lineSub?.cancel());
    _controller?.dispose();
    _steadySecField.dispose();
    _logField.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  void _appendLine(String line) {
    _logField.text = '${_logField.text}$line\n';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runGuarded(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _appendLine('ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _abort() => _controller!.abort();

  void _clearLog() => setState(_logField.clear);

  Future<void> _startSweep() {
    final steadySec = int.tryParse(_steadySecField.text) ?? 10;
    final backends = {if (_opfs) 'opfs', if (_idb) 'idb', if (_drift) 'drift'};
    return _runGuarded(
      () => _controller!.runSweep(
        workload: _workload,
        steadySec: steadySec,
        backends: backends,
        idbIncludeDefaultDurability: _idbDefaultDurability,
        includeBlast: _blast,
      ),
    );
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: _logField.text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Log copied')));
    }
  }

  Future<void> _copyResults() async {
    final controller = _controller!;
    await Clipboard.setData(ClipboardData(text: controller.resultsCsv()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${controller.results.length} result rows copied'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return const Scaffold(
        body: Center(child: Text('Storage benchmark runs on web builds.')),
      );
    }
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<Workload>(
                  segments: const [
                    ButtonSegment(
                      value: Workload.today,
                      label: Text('Today · 12 kB/s'),
                    ),
                    ButtonSegment(
                      value: Workload.upper,
                      label: Text('Upper · 1.5 MB/s'),
                    ),
                  ],
                  selected: {_workload},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() => _workload = s.first),
                ),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _steadySecField,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'steady s/run',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                FilterChip(
                  label: const Text('OPFS'),
                  selected: _opfs,
                  onSelected: _busy ? null : (v) => setState(() => _opfs = v),
                ),
                FilterChip(
                  label: const Text('IndexedDB'),
                  selected: _idb,
                  onSelected: _busy ? null : (v) => setState(() => _idb = v),
                ),
                FilterChip(
                  label: const Text('Drift'),
                  selected: _drift,
                  onSelected: _busy ? null : (v) => setState(() => _drift = v),
                ),
                FilterChip(
                  label: const Text('IDB default durability'),
                  selected: _idbDefaultDurability,
                  onSelected: _busy || !_idb
                      ? null
                      : (v) => setState(() => _idbDefaultDurability = v),
                ),
                FilterChip(
                  label: const Text('Blast ceiling'),
                  selected: _blast,
                  onSelected: _busy ? null : (v) => setState(() => _blast = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _runGuarded(() => _controller!.probe()),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Probe'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _startSweep,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run sweep'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? _abort : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Abort'),
                ),
                OutlinedButton.icon(
                  onPressed: _copyResults,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy results CSV'),
                ),
                OutlinedButton.icon(
                  onPressed: _copyLog,
                  icon: const Icon(Icons.content_copy),
                  label: const Text('Copy log'),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _clearLog,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _logField,
                scrollController: _logScroll,
                readOnly: true,
                expands: true,
                maxLines: null,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
