import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../models/load_cell.dart';
import 'channel_palette.dart';

@immutable
class ChannelStatsRow {
  const ChannelStatsRow({
    required this.label,
    required this.values,
    this.emphasized = false,
    this.stale = false,
  });

  /// Row label shown in the leading column.
  final String label;

  /// One value per channel, in [ChannelStatsTable.unit] units; null means the
  /// unit is unavailable (renders '-').
  final List<double?> values;

  /// Primary-reading styling (larger, bold).
  final bool emphasized;

  /// Dim the values (a stale reading).
  final bool stale;
}

/// Per-channel stats grid.
///
/// The value cells are composed from a glyph atlas instead of `Text` widgets.
/// This table re-lays-out on every packet; the per-cell paragraph shaping that
/// a normal `Text`/`Table` build does was the dominant cost on low-end web
/// (see profiling/investigation/FINDINGS4.md). Static text — row labels, the
/// channel header, the unit caption, the clipping icon — stays as widgets,
/// since it only lays out when configuration changes.
///
/// Value rows sit behind a [RepaintBoundary] so only the row whose digits
/// changed re-records; the rest are blitted from their retained layer.
class ChannelStatsTable extends StatefulWidget {
  ChannelStatsTable({
    super.key,
    required this.labels,
    required this.activeChannels,
    required this.onToggleChannel,
    required this.unit,
    required this.rows,
    this.clipped,
  }) : assert(
         _oneValuePerChannel(labels, activeChannels, rows, clipped),
         'labels, activeChannels, rows and clipped must agree in length',
       );

  static bool _oneValuePerChannel(
    List<String> labels,
    List<bool> activeChannels,
    List<ChannelStatsRow> rows,
    List<bool>? clipped,
  ) =>
      activeChannels.length == labels.length &&
      rows.every((r) => r.values.length == labels.length) &&
      (clipped == null || clipped.length == labels.length);

  final List<String> labels;

  /// Whether each channel is enabled; inactive ones show '--' and are dimmed.
  final List<bool> activeChannels;

  /// Called with the channel index when any of its cells is tapped.
  final ValueChanged<int> onToggleChannel;

  /// Unit the row [ChannelStatsRow.values] are expressed in.
  final DisplayUnit unit;

  /// Stat rows below the channel header.
  final List<ChannelStatsRow> rows;

  /// Per-channel ADC-rail flag; null = no status display.
  final List<bool>? clipped;

  @override
  State<ChannelStatsTable> createState() => _ChannelStatsTableState();
}

class _ChannelStatsTableState extends State<ChannelStatsTable> {
  _GlyphAtlas? _monoAtlas;
  _GlyphAtlas? _emphAtlas;
  Object? _atlasKey;

  double? _col0Width;
  Object? _col0Key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureAtlases();
  }

  @override
  void dispose() {
    _monoAtlas?.dispose();
    _emphAtlas?.dispose();
    super.dispose();
  }

  ({TextStyle mono, TextStyle emph}) _styles(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const tabular = [FontFeature.tabularFigures()];
    return (
      mono:
          text.bodySmall?.copyWith(fontFeatures: tabular) ??
          const TextStyle(fontFeatures: tabular),
      emph:
          text.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            fontFeatures: tabular,
          ) ??
          const TextStyle(fontWeight: FontWeight.bold, fontFeatures: tabular),
    );
  }

  void _ensureAtlases() {
    final styles = _styles(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final key = (styles.mono, styles.emph, textScaler, dpr);
    if (key == _atlasKey) return;
    _monoAtlas?.dispose();
    _emphAtlas?.dispose();
    _monoAtlas = _GlyphAtlas.build(
      style: styles.mono,
      textScaler: textScaler,
      dpr: dpr,
    );
    _emphAtlas = _GlyphAtlas.build(
      style: styles.emph,
      textScaler: textScaler,
      dpr: dpr,
    );
    _atlasKey = key;
  }

  /// Leading column width = widest row label at [headerStyle]. Measured with a
  /// paragraph once per (labels, style, scale); the labels are static text.
  double _col0(TextStyle headerStyle) {
    final labels = [for (final r in widget.rows) r.label];
    final textScaler = MediaQuery.textScalerOf(context);
    final key = (labels.join('\u0000'), headerStyle, textScaler);
    if (key == _col0Key) return _col0Width!;
    var width = 0.0;
    for (final label in labels) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: headerStyle),
        textScaler: textScaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (tp.width > width) width = tp.width;
    }
    _col0Key = key;
    _col0Width = width;
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final staleColor = scheme.outline;
    final headerStyle =
        theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold) ??
        const TextStyle(fontWeight: FontWeight.bold);
    final styles = _styles(context);
    final monoAtlas = _monoAtlas!;
    final emphAtlas = _emphAtlas!;
    final col0 = _col0(headerStyle);
    final channelCount = widget.labels.length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(width: col0),
                  for (int i = 0; i < channelCount; i++)
                    Expanded(child: _headerCell(context, i, staleColor)),
                ],
              ),
              Row(
                children: [
                  SizedBox(width: col0),
                  for (int i = 0; i < channelCount; i++)
                    Expanded(child: _colorBarCell(i, staleColor)),
                ],
              ),
              for (final row in widget.rows)
                _valueRow(
                  row,
                  labelStyle: headerStyle,
                  baseStyle: row.emphasized ? styles.emph : styles.mono,
                  atlas: row.emphasized ? emphAtlas : monoAtlas,
                  col0: col0,
                  channelCount: channelCount,
                  staleColor: staleColor,
                  onSurface: scheme.onSurface,
                ),
            ],
          ),
          Positioned(
            top: 13,
            left: 0,
            child: Text('In ${widget.unit.symbol}', style: headerStyle),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(BuildContext context, int channel, Color staleColor) {
    final active = widget.activeChannels[channel];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Fixed-width slot so the label never reflows; outside the toggle so
          // a tap shows the tooltip.
          SizedBox(
            width: 20,
            height: 16,
            child: active
                ? _ClipStatusIcon(
                    clipped: widget.clipped?[channel] ?? false,
                    channel: channel,
                  )
                : null,
          ),
          Flexible(
            child: _TappableChannelCell(
              channel: channel,
              active: active,
              onTap: () => widget.onToggleChannel(channel),
              child: Text(
                widget.labels[channel],
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active
                      ? getChannelColor(channel)
                      : staleColor.withValues(alpha: 0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorBarCell(int channel, Color staleColor) {
    final active = widget.activeChannels[channel];
    return _TappableChannelCell(
      channel: channel,
      active: active,
      onTap: () => widget.onToggleChannel(channel),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
        child: Container(
          height: 3,
          color: active
              ? getChannelColor(channel)
              : staleColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }

  Widget _valueRow(
    ChannelStatsRow row, {
    required TextStyle labelStyle,
    required TextStyle baseStyle,
    required _GlyphAtlas atlas,
    required double col0,
    required int channelCount,
    required Color staleColor,
    required Color onSurface,
  }) {
    // 1px vertical padding around the line, as the old table cells had.
    final rowHeight = atlas.lineHeight + 2;
    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: col0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(row.label, style: labelStyle),
            ),
          ),
          Expanded(
            child: RepaintBoundary(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < channelCount; i++)
                    Expanded(
                      child: _valueCell(
                        channel: i,
                        value: row.values[i],
                        active: widget.activeChannels[i],
                        stale: row.stale,
                        atlas: atlas,
                        baseStyle: baseStyle,
                        staleColor: staleColor,
                        onSurface: onSurface,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _valueCell({
    required int channel,
    required double? value,
    required bool active,
    required bool stale,
    required _GlyphAtlas atlas,
    required TextStyle baseStyle,
    required Color staleColor,
    required Color onSurface,
  }) {
    final text = !active
        ? '--'
        : (value == null ? '-' : widget.unit.formatValueOnly(value));
    final color = !active
        ? staleColor.withValues(alpha: 0.4)
        : ((stale || value == null)
              ? staleColor
              : (baseStyle.color ?? onSurface));
    return _TappableChannelCell(
      channel: channel,
      active: active,
      onTap: () => widget.onToggleChannel(channel),
      valueText: text,
      child: CustomPaint(
        painter: ChannelStatsCellPainter._(
          atlas: atlas,
          text: text,
          color: color,
        ),
      ),
    );
  }
}

/// Rasterized digits and punctuation for one text style, tinted per draw.
///
/// The inventory is the closed set the formatters can emit ([DisplayUnit]
/// writes a sign, digits, and a decimal point; the table adds '--' for an
/// inactive channel and '-' for an unavailable value). A character outside it
/// means a formatter changed; that is a bug, so [glyph] throws.
class _GlyphAtlas {
  _GlyphAtlas._({
    required this.image,
    required this.glyphs,
    required this.lineHeight,
    required this.dpr,
  });

  static const String _inventory = '0123456789.+-';

  final ui.Image image;

  /// Indexed by code unit; null for a character not in [_inventory].
  final List<_Glyph?> glyphs;

  /// Line height of the source style, in logical pixels.
  final double lineHeight;

  /// Device pixel ratio the atlas was rasterized at; draw-time scaling is
  /// `1 / dpr`.
  final double dpr;

  static _GlyphAtlas build({
    required TextStyle style,
    required TextScaler textScaler,
    required double dpr,
  }) {
    // A pure coverage mask: [ChannelStatsCellPainter] tints with dstIn, which
    // takes only the atlas alpha and replaces its RGB, so the glyphs are baked
    // opaque-white regardless of the style's color.
    final mask = style.copyWith(color: Colors.white);
    final probe = TextPainter(
      text: TextSpan(text: '0', style: mask),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final lineHeight = probe.height;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    final glyphs = List<_Glyph?>.filled(128, null);
    var x = 0.0;
    for (final ch in _inventory.split('')) {
      final tp = TextPainter(
        text: TextSpan(text: ch, style: mask),
        textScaler: textScaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      tp.paint(canvas, Offset(x, 0));
      glyphs[ch.codeUnitAt(0)] = _Glyph(
        src: Rect.fromLTRB(x * dpr, 0, (x + tp.width) * dpr, lineHeight * dpr),
        advance: tp.width,
      );
      x += tp.width;
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (x * dpr).ceil(),
      (lineHeight * dpr).ceil(),
    );
    picture.dispose();
    return _GlyphAtlas._(
      image: image,
      glyphs: glyphs,
      lineHeight: lineHeight,
      dpr: dpr,
    );
  }

  _Glyph glyph(int codeUnit) {
    final glyph = codeUnit < glyphs.length ? glyphs[codeUnit] : null;
    if (glyph == null) {
      throw StateError(
        'stats-table glyph atlas has no glyph for '
        'U+${codeUnit.toRadixString(16).toUpperCase()}',
      );
    }
    return glyph;
  }

  void dispose() => image.dispose();
}

@immutable
class _Glyph {
  const _Glyph({required this.src, required this.advance});

  /// Source rectangle in the atlas image (physical pixels).
  final Rect src;

  /// Advance width in logical pixels.
  final double advance;
}

/// Paints one channel's value by blitting atlas glyphs, right-aligned. No
/// paragraph is laid out or recorded here.
///
/// Public so widget tests can assert the painted text (the values are no
/// longer `Text` widgets).
class ChannelStatsCellPainter extends CustomPainter {
  ChannelStatsCellPainter._({
    required _GlyphAtlas atlas,
    required this.text,
    required this.color,
  }) : _atlas = atlas {
    var x = 0.0;
    for (final codeUnit in text.codeUnits) {
      final glyph = _atlas.glyph(codeUnit);
      _rects.add(glyph.src);
      _transforms.add(
        ui.RSTransform(1 / _atlas.dpr, 0, x - glyph.src.left / _atlas.dpr, 0),
      );
      _colors.add(color);
      x += glyph.advance;
    }
    _width = x;
  }

  /// Cell padding, matching the old value cells.
  static const double _padding = 1;

  static final Paint _paint = Paint()..filterQuality = FilterQuality.none;

  final _GlyphAtlas _atlas;

  /// The formatted value shown in the cell.
  final String text;
  final Color color;

  final List<ui.RSTransform> _transforms = [];
  final List<Rect> _rects = [];
  final List<Color> _colors = [];
  double _width = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final dpr = _atlas.dpr;
    final x = ((size.width - _padding - _width) * dpr).roundToDouble() / dpr;
    final y =
        (((size.height - _atlas.lineHeight) / 2) * dpr).roundToDouble() / dpr;
    canvas.save();
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);
    canvas.translate(x, y);
    // dstIn: the atlas part is the source, the color the destination, so the
    // result is [color] shaped by the glyph's alpha.
    canvas.drawAtlas(
      _atlas.image,
      _transforms,
      _rects,
      _colors,
      BlendMode.dstIn,
      null,
      _paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChannelStatsCellPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.color != color ||
      oldDelegate._atlas != _atlas;
}

/// ADC-rail warning icon: snaps on at the first clipped sample and fades out
/// once clear, so a hovering rail reads as steady. The subtree unmounts when
/// faded (an opacity-zero tooltip trigger would still answer pointer hits).
class _ClipStatusIcon extends StatefulWidget {
  const _ClipStatusIcon({required this.clipped, required this.channel});

  /// Instantaneous rail flag.
  final bool clipped;
  final int channel;

  static const Duration _fadeOut = Duration(milliseconds: 800);

  @override
  State<_ClipStatusIcon> createState() => _ClipStatusIconState();
}

class _ClipStatusIconState extends State<_ClipStatusIcon> {
  /// Whether the icon is fully faded and unmounted. A never-clipped channel
  /// mounts nothing, and the initial zero-opacity build never animates, so
  /// [AnimatedOpacity.onEnd] alone can't be relied on.
  bool _gone = true;

  @override
  void initState() {
    super.initState();
    _gone = !widget.clipped;
  }

  @override
  void didUpdateWidget(_ClipStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The zero-duration fade-in makes the reappearance instant in this
    // build; no setState needed since a build follows didUpdateWidget.
    if (widget.clipped) _gone = false;
  }

  void _onFadeEnd() {
    if (!widget.clipped) setState(() => _gone = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.clipped && _gone) return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: widget.clipped ? 1.0 : 0.0,
      duration: widget.clipped ? Duration.zero : _ClipStatusIcon._fadeOut,
      onEnd: _onFadeEnd,
      child: Tooltip(
        message:
            '${rigSlotTitle(widget.channel)} is at the ADC rail. The reading is clipping.',
        triggerMode: TooltipTriggerMode.tap,
        child: Icon(
          Icons.warning_rounded,
          size: 14,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

/// Tap-target wrapper for a channel cell: pointer cursor, opaque hit testing,
/// the toggle callback, and screen-reader semantics.
class _TappableChannelCell extends StatelessWidget {
  const _TappableChannelCell({
    required this.channel,
    required this.active,
    required this.onTap,
    required this.child,
    this.valueText,
  });

  final int channel;
  final bool active;
  final VoidCallback onTap;
  final Widget child;

  /// The painted value, announced to screen readers; null for non-value cells.
  final String? valueText;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        toggled: active,
        label: rigSlotTitle(channel),
        value: valueText,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}
