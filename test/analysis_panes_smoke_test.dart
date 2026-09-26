import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/analysis_pane.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/analysis_pane_bar.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Paint smoke tests for the analysis panes: every pane kind renders over
/// real hub data without throwing, and the selector bar edits the
/// selection. No pixel assertions — the point is the paint paths executing
/// end to end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  /// Same nominal-chain fixture as channel_limits_test.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  /// A hub with a few seconds of positive-going tones per channel (positive
  /// so the balance plate has load to place).
  DataHub hubWithData() {
    final hub = DataHub();
    hub.updateBoardCalibration(
      ProvisionedBoardCalibration(
        nominals: BoardNominals(
          adcFsrV: testNominals.adcFsrV,
          afeGain: testNominals.afeGain,
          excitationV: testNominals.excitationV,
          pgaGains: const [1, 1, 1, 1],
        ),
      ),
    );
    final frame = Int32List(channels);
    final cpmv = testNominals.countsPerMvV;
    for (var i = 0; i < 3000; i++) {
      for (var ch = 0; ch < channels; ch++) {
        final base = (ch + 2) * 0.3 * cpmv;
        final wobble = 0.02 * cpmv * math.sin(2 * math.pi * 10 * i / 1000);
        frame[ch] =
            (base * (1 + 0.05 * math.sin(2 * math.pi * 0.5 * i / 1000)) +
                    wobble)
                .round();
      }
      hub.addSampleFrame(frame);
    }
    return hub;
  }

  testWidgets('every analysis pane paints over session-like data', (
    tester,
  ) async {
    final hub = hubWithData();
    final ctrl = GraphController();

    const variants = <AnalysisPaneSelection>[
      AnalysisPaneSelection(kind: AnalysisPaneKind.derivative),
      AnalysisPaneSelection(kind: AnalysisPaneKind.sum),
      AnalysisPaneSelection(kind: AnalysisPaneKind.sum, sumChannels: {1, 3}),
      AnalysisPaneSelection(kind: AnalysisPaneKind.diff),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.diff,
        diffA: 2,
        diffB: 2, // degenerate pair: the pane must say so, not plot
      ),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.balance,
        balanceMode: BalanceMode.line,
      ),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.balance,
        balanceMode: BalanceMode.plate,
      ),
      AnalysisPaneSelection(kind: AnalysisPaneKind.fft),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.fft,
        fftN: 4096,
        fftAsd: true,
        fftChannels: {0, 2},
      ),
    ];

    for (final analysis in variants) {
      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkspace(
            data: hub,
            ctrl: ctrl,
            unit: DisplayUnit.mVv,
            activeChannels: [for (int i = 0; i < channels; i++) i],
            analysis: analysis,
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester.takeException(),
        isNull,
        reason: 'pane failed to paint: $analysis',
      );
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the pane bar selects panes and edits their parameters', (
    tester,
  ) async {
    var selection = const AnalysisPaneSelection();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AnalysisPaneBar(
              selection: selection,
              onChanged: (s) => setState(() => selection = s),
            ),
          ),
        ),
      ),
    );

    // FFT params: N, mode, channel toggles.
    await tester.tap(find.text('FFT'));
    await tester.pump();
    expect(selection.kind, AnalysisPaneKind.fft);
    await tester.tap(find.text('4k'));
    await tester.pump();
    expect(selection.fftN, 4096);
    await tester.tap(find.text('/√Hz'));
    await tester.pump();
    expect(selection.fftAsd, isTrue);
    await tester.tap(find.widgetWithText(FilterChip, 'CH 2'));
    await tester.pump();
    expect(selection.fftChannels, {0, 1, 3});

    // Balance plate corner cycling keeps the assignment a permutation.
    await tester.tap(find.text('Balance'));
    await tester.pump();
    await tester.tap(find.text('TL · CH 0'));
    await tester.pump();
    expect(selection.balanceCorners.toSet(), {0, 1, 2, 3});
    expect(selection.balanceCorners[0], 1);
    await tester.tap(find.text('1D line'));
    await tester.pump();
    expect(selection.balanceMode, BalanceMode.line);

    // Tapping the active pane chip collapses the slot.
    await tester.tap(find.text('Balance'));
    await tester.pump();
    expect(selection.kind, isNull);

    expect(tester.takeException(), isNull);
  });
}
