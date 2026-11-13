import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../models/load_cell.dart';
import 'channel_palette.dart';

@immutable
class ChannelStatsRow {
  const new({
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
/// Value cells are painted from cached single-character paragraphs instead of
/// `Text` widgets: the whole `Text`/`Table` layout measured at 7.7-9.6 ms per
/// call under an 8x CPU throttle on web. Paragraphs are laid out for the fixed
/// numeric character inventory when text configuration changes, never when a
/// number changes. Static labels and headers remain widgets.
///
/// Value rows sit behind a [RepaintBoundary] so only the row whose digits
/// changed re-records; the rest are blitted from their retained layer.
class ChannelStatsTable extends StatefulWidget {
  new({
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

/// Per-build values every value cell needs, resolved once in [build].
typedef _Grid = ({
  TextStyle labelStyle,
  double col0,
  int channelCount,
  Color staleColor,
  Color onSurface,
});

class _ChannelStatsTableState extends State<ChannelStatsTable> {
  _GlyphFont? _monoFont;
  _GlyphFont? _emphFont;
  Object? _fontKey;

  double? _col0Width;
  Object? _col0Key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureFonts();
  }

  @override
  void dispose() {
    _monoFont?.dispose();
    _emphFont?.dispose();
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
            fontWeight: .bold,
            fontFeatures: tabular,
          ) ??
          const TextStyle(fontWeight: FontWeight.bold, fontFeatures: tabular),
    );
  }

  void _ensureFonts() {
    final styles = _styles(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final scheme = Theme.of(context).colorScheme;
    final key = (
      styles.mono,
      styles.emph,
      textScaler,
      scheme.onSurface,
      scheme.outline,
    );
    if (key == _fontKey) return;
    _monoFont?.dispose();
    _emphFont?.dispose();
    _monoFont = _GlyphFont.build(
      style: styles.mono,
      textScaler: textScaler,
      fallbackNormalColor: scheme.onSurface,
      staleColor: scheme.outline,
    );
    _emphFont = _GlyphFont.build(
      style: styles.emph,
      textScaler: textScaler,
      fallbackNormalColor: scheme.onSurface,
      staleColor: scheme.outline,
    );
    _fontKey = key;
  }

  /// Leading column width = widest row label at [labelStyle]. Measured with a
  /// paragraph once per (labels, style, scale); the labels are static text.
  double _col0(TextStyle labelStyle) {
    final labels = [for (final r in widget.rows) r.label];
    final textScaler = MediaQuery.textScalerOf(context);
    final key = (labels.join('\u0000'), labelStyle, textScaler);
    if (key == _col0Key) return _col0Width!;
    var width = 0.0;
    for (final label in labels) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textScaler: textScaler,
        textDirection: .ltr,
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
    final labelStyle =
        theme.textTheme.labelSmall?.copyWith(fontWeight: .bold) ??
        const TextStyle(fontWeight: FontWeight.bold);
    final grid = (
      labelStyle: labelStyle,
      col0: _col0(labelStyle),
      channelCount: widget.labels.length,
      staleColor: scheme.outline,
      onSurface: scheme.onSurface,
    );
    final styles = _styles(context);
    final monoFont = _monoFont!;
    final emphFont = _emphFont!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: .stretch,
            children: [
              Row(
                children: [
                  SizedBox(width: grid.col0),
                  for (int i = 0; i < grid.channelCount; i++)
                    Expanded(child: _headerCell(context, i, grid.staleColor)),
                ],
              ),
              Row(
                children: [
                  SizedBox(width: grid.col0),
                  for (int i = 0; i < grid.channelCount; i++)
                    Expanded(child: _colorBarCell(i, grid.staleColor)),
                ],
              ),
              for (final row in widget.rows)
                _valueRow(
                  row,
                  grid: grid,
                  baseStyle: row.emphasized ? styles.emph : styles.mono,
                  font: row.emphasized ? emphFont : monoFont,
                ),
            ],
          ),
          Positioned(
            top: 13,
            left: 0,
            child: Text('In ${widget.unit.symbol}', style: grid.labelStyle),
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
        mainAxisAlignment: .end,
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
                textAlign: .right,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active
                      ? getChannelColor(channel)
                      : staleColor.withValues(alpha: 0.5),
                ),
                maxLines: 1,
                overflow: .ellipsis,
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
    required _Grid grid,
    required TextStyle baseStyle,
    required _GlyphFont font,
  }) {
    // 1px vertical padding around the line, as the old table cells had.
    final rowHeight = font.lineHeight + 2;
    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: .stretch,
        children: [
          SizedBox(
            width: grid.col0,
            child: Align(
              alignment: .centerLeft,
              child: Text(row.label, style: grid.labelStyle),
            ),
          ),
          Expanded(
            child: RepaintBoundary(
              child: Row(
                crossAxisAlignment: .stretch,
                children: [
                  for (int i = 0; i < grid.channelCount; i++)
                    Expanded(
                      child: _valueCell(
                        channel: i,
                        value: row.values[i],
                        active: widget.activeChannels[i],
                        stale: row.stale,
                        font: font,
                        baseStyle: baseStyle,
                        grid: grid,
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
    required _GlyphFont font,
    required TextStyle baseStyle,
    required _Grid grid,
  }) {
    final text = !active
        ? '--'
        : (value == null ? '-' : widget.unit.formatValueOnly(value));
    final color = !active
        ? grid.staleColor.withValues(alpha: 0.4)
        : ((stale || value == null)
              ? grid.staleColor
              : (baseStyle.color ?? grid.onSurface));
    return _TappableChannelCell(
      channel: channel,
      active: active,
      onTap: () => widget.onToggleChannel(channel),
      valueText: text,
      child: CustomPaint(
        painter: ChannelStatsCellPainter._(
          glyphs: font.forColor(color),
          text: text,
        ),
      ),
    );
  }
}

/// The numeric character inventory for one base style, in every color used by
/// the table. Preparing every variant avoids a first-use layout when a row
/// becomes stale or a channel is toggled.
class _GlyphFont {
  new _({required this.variants, required this.lineHeight});

  final Map<Color, _GlyphSet> variants;
  final double lineHeight;

  static _GlyphFont build({
    required TextStyle style,
    required TextScaler textScaler,
    required Color fallbackNormalColor,
    required Color staleColor,
  }) {
    final normalColor = style.color ?? fallbackNormalColor;
    final variants = <Color, _GlyphSet>{};
    for (final color in {
      normalColor,
      staleColor,
      staleColor.withValues(alpha: 0.4),
    }) {
      variants[color] = _GlyphSet.build(
        style: style.copyWith(color: color),
        textScaler: textScaler,
      );
    }
    return _GlyphFont._(
      variants: variants,
      lineHeight: variants[normalColor]!.lineHeight,
    );
  }

  _GlyphSet forColor(Color color) => variants[color]!;

  void dispose() {
    for (final glyphs in variants.values) {
      glyphs.dispose();
    }
  }
}

/// Native paragraphs for the closed set of characters emitted by
/// [DisplayUnit], plus the table's '-' and '--' placeholders. Isolating a
/// character is valid for this numeric font: tabular figures have fixed
/// advances, and these characters do not form ligatures.
class _GlyphSet {
  new _({required this.glyphs, required this.lineHeight});

  static const String _inventory = '0123456789.+-';

  /// Indexed by code unit; null for a character not in [_inventory].
  final List<TextPainter?> glyphs;
  final double lineHeight;

  static _GlyphSet build({
    required TextStyle style,
    required TextScaler textScaler,
  }) {
    final glyphs = List<TextPainter?>.filled(128, null);
    for (final ch in _inventory.split('')) {
      glyphs[ch.codeUnitAt(0)] = TextPainter(
        text: TextSpan(text: ch, style: style),
        textScaler: textScaler,
        textDirection: .ltr,
        maxLines: 1,
      )..layout();
    }
    return _GlyphSet._(
      glyphs: glyphs,
      lineHeight: glyphs['0'.codeUnitAt(0)]!.height,
    );
  }

  TextPainter glyph(int codeUnit) {
    final glyph = codeUnit < glyphs.length ? glyphs[codeUnit] : null;
    if (glyph == null) {
      throw StateError(
        'stats-table character cache has no glyph for '
        'U+${codeUnit.toRadixString(16).toUpperCase()}',
      );
    }
    return glyph;
  }

  void dispose() {
    for (final glyph in glyphs) {
      glyph?.dispose();
    }
  }
}

/// Paints one channel's value with cached character paragraphs, right-aligned.
/// Values require no paragraph layout after [_GlyphFont.build].
///
/// Public so widget tests can assert the painted text (the values are no
/// longer `Text` widgets).
class ChannelStatsCellPainter extends CustomPainter {
  new _({required _GlyphSet glyphs, required this.text}) : _glyphs = glyphs {
    var width = 0.0;
    for (final codeUnit in text.codeUnits) {
      final glyph = glyphs.glyph(codeUnit);
      _characters.add(glyph);
      width += glyph.width;
    }
    _width = width;
  }

  static const double _padding = 1;

  final _GlyphSet _glyphs;
  final List<TextPainter> _characters = [];
  double _width = 0;

  /// The formatted value shown in the cell.
  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    var x = size.width - _padding - _width;
    final y = (size.height - _glyphs.lineHeight) / 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);
    for (final character in _characters) {
      character.paint(canvas, Offset(x, y));
      x += character.width;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChannelStatsCellPainter oldDelegate) =>
      oldDelegate.text != text || oldDelegate._glyphs != _glyphs;
}

/// ADC-rail warning icon: snaps on at the first clipped sample and fades out
/// once clear, so a hovering rail reads as steady. The subtree unmounts when
/// faded (an opacity-zero tooltip trigger would still answer pointer hits).
class _ClipStatusIcon extends StatefulWidget {
  const new({required this.clipped, required this.channel});

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
        triggerMode: .tap,
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
  const new({
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
        child: GestureDetector(behavior: .opaque, onTap: onTap, child: child),
      ),
    );
  }
}
