import 'package:flutter/foundation.dart';

/// Profiling-only aggregates for graph paint work and whole-frame timings.
///
/// Graph surfaces feed painter and tile-cache activity into this global sink;
/// the Live tab's FrameTiming callback feeds [addFrame]. Every 60 frames the
/// measurements are printed together and the next reporting window starts.
class PerfStats {
  static const int _reportEvery = 60;

  static int _paintCount = 0;
  static int _paintMicros = 0;

  /// Record one force/derivative painter's UI-isolate draw-call construction.
  static void addPaint(int micros) {
    _paintMicros += micros;
    _paintCount++;
  }

  static int _tileGapBakes = 0;
  static int _tileRefreshBakes = 0;
  static int _tileBlits = 0;
  static int _tileDirect = 0;

  /// Record one planned tile bake: uncovered-range fill versus stale refresh.
  static void addTileBake({required bool gap}) {
    if (gap) {
      _tileGapBakes++;
    } else {
      _tileRefreshBakes++;
    }
  }

  /// Record the number of cached-image blits and direct vector gap renders.
  static void addTileDraws({required int blits, required int direct}) {
    _tileBlits += blits;
    _tileDirect += direct;
  }

  static int _frameCount = 0;
  static int _rasterMicros = 0;
  static int _buildMicros = 0;

  /// Feed one FrameTiming. Emits the combined report every 60 frames.
  static void addFrame(int rasterMicros, int buildMicros) {
    _rasterMicros += rasterMicros;
    _buildMicros += buildMicros;
    _frameCount++;
    if (_frameCount >= _reportEvery) _report();
  }

  static void _report() {
    final dartAvg = _paintCount > 0 ? _paintMicros / _paintCount : 0;
    final rasterAvg = _rasterMicros / _frameCount;
    final buildAvg = _buildMicros / _frameCount;
    debugPrint(
      '[PERF] over $_frameCount frames | '
      'Main paint: ${dartAvg.toStringAsFixed(0)}us (${_paintCount}x) | '
      'tiles/frame: ${(_tileBlits / _frameCount).toStringAsFixed(1)} blit, '
      '${(_tileDirect / _frameCount).toStringAsFixed(1)} direct | '
      'bakes: ${_tileGapBakes}g+${_tileRefreshBakes}r | '
      'Raster: ${rasterAvg.toStringAsFixed(0)}us | '
      'build: ${buildAvg.toStringAsFixed(0)}us',
    );
    _paintCount = 0;
    _paintMicros = 0;
    _tileGapBakes = 0;
    _tileRefreshBakes = 0;
    _tileBlits = 0;
    _tileDirect = 0;
    _frameCount = 0;
    _rasterMicros = 0;
    _buildMicros = 0;
  }
}
