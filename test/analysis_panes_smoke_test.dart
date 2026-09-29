import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/analysis_pane.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/derived_channel.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/load_cell.dart';
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

  const plateLabels = ['CH 0', 'CH 1', 'CH 2', 'CH 3', 'Σ', 'X', 'Y', 'Err'];

  /// A hub with the force-plate derived channels configured and a few
  /// seconds of positive-going tones per channel (positive so the plate
  /// ratio has load to place). [cells] binds the derived channels.
  DataHub hubWithData({bool cells = false}) {
    final hub = DataHub();
    hub.updateDerivedChannels(forcePlateChannels(const [0, 1, 2, 3]));
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
    if (cells) {
      hub.updateLoadCells([
        for (int i = 0; i < channels; i++)
          const LoadCellProfile(capacityKg: 200, sensitivityMvV: 2),
      ]);
    }
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
    final hub = hubWithData(cells: true);
    final ctrl = GraphController();

    const variants = <AnalysisPaneSelection>[
      AnalysisPaneSelection(kind: AnalysisPaneKind.derivative),
      AnalysisPaneSelection(kind: AnalysisPaneKind.plate),
      AnalysisPaneSelection(kind: AnalysisPaneKind.readout),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.readout,
        readoutChannel: 2, // a hardware channel also binds
      ),
      AnalysisPaneSelection(kind: AnalysisPaneKind.fft),
      AnalysisPaneSelection(
        kind: AnalysisPaneKind.fft,
        fftN: 4096,
        fftAsd: true,
        fftChannels: {0, 2, 4}, // includes a derived (blend) channel
      ),
    ];

    for (final analysis in variants) {
      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkspace(
            data: hub,
            ctrl: ctrl,
            unit: DisplayUnit.kgf,
            activeChannels: [for (int i = 0; i < kMaxChannelCount; i++) i],
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

  testWidgets('unbound derived channels keep the panes painting', (
    tester,
  ) async {
    // No load cells: the derived channels can't bind; every pane must say
    // so without throwing (the hardware channels still do).
    final hub = hubWithData();
    await tester.pumpWidget(
      MaterialApp(
        home: GraphWorkspace(
          data: hub,
          ctrl: GraphController(),
          unit: DisplayUnit.mVv,
          activeChannels: const [0, 1, 2, 3],
          analysis: const AnalysisPaneSelection(kind: AnalysisPaneKind.plate),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);

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
              channelLabels: plateLabels,
              channelUnitless: const [
                false,
                false,
                false,
                false,
                false,
                true,
                true,
                true,
              ],
            ),
          ),
        ),
      ),
    );

    // FFT params: N, mode, channel toggles (hardware and derived alike).
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
    await tester.tap(find.widgetWithText(FilterChip, 'Σ'));
    await tester.pump();
    expect(selection.fftChannels, {0, 1, 3, 4});

    // Tapping the active pane chip collapses the slot.
    await tester.tap(find.text('FFT'));
    await tester.pump();
    expect(selection.kind, isNull);

    expect(tester.takeException(), isNull);
  });
}
