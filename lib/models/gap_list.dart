import 'dart:convert';

/// Sorted, disjoint, half-open `[start, end)` ranges of missing samples, in
/// absolute sample indices.
///
/// This is the single home of gap bookkeeping: the [DataHub] appends ranges as
/// the decoder detects dropped packets, renderers query [contains]/[rangesIn],
/// and sessions persist/reload them via [toJson]/[GapList.fromJson]. The ring
/// buffer itself holds ordinary (held) values inside gaps, so nothing else in
/// the pipeline needs to know about missing data.
class GapList {
  GapList();

  /// Flat `[start0, end0, start1, end1, ...]` storage, sorted and disjoint.
  final List<int> _bounds = [];

  bool get isEmpty => _bounds.isEmpty;

  /// Whether sample [i] falls inside a gap.
  bool contains(int i) {
    if (_bounds.isEmpty) return false; // common zero-gap fast path
    // Binary search for the last bound <= i; i is inside a gap iff that bound
    // is a range start (even index).
    int lo = 0, hi = _bounds.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_bounds[mid] <= i) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo.isOdd; // odd insertion point => last bound <= i was a start
  }

  /// The gap ranges overlapping `[start, end)`, clamped to it.
  Iterable<(int, int)> rangesIn(int start, int end) sync* {
    for (int k = 0; k < _bounds.length; k += 2) {
      final s = _bounds[k];
      final e = _bounds[k + 1];
      if (e <= start) continue;
      if (s >= end) break;
      yield (s < start ? start : s, e > end ? end : e);
    }
  }

  /// Append the gap `[start, end)`. Ranges only ever arrive at the live edge
  /// (monotonically increasing), so this merges with the trailing range or
  /// appends after it.
  void append(int start, int end) {
    if (end <= start) return;
    assert(
      _bounds.isEmpty || start >= _bounds.last,
      'append must be at the live edge',
    );
    if (_bounds.isNotEmpty && _bounds.last == start) {
      _bounds[_bounds.length - 1] = end; // extend the trailing range
    } else {
      _bounds
        ..add(start)
        ..add(end);
    }
  }

  /// Drop (or clamp) ranges entirely before [oldest] — ring-wrap hygiene.
  void pruneBefore(int oldest) {
    if (_bounds.isEmpty || _bounds.first >= oldest) return;
    int k = 0;
    while (k < _bounds.length && _bounds[k + 1] <= oldest) {
      k += 2;
    }
    _bounds.removeRange(0, k);
    if (_bounds.isNotEmpty && _bounds.first < oldest) {
      _bounds[0] = oldest;
    }
  }

  void clear() => _bounds.clear();

  /// JSON-encode as `[[start,end],...]`.
  String toJson() => jsonEncode([
    for (int k = 0; k < _bounds.length; k += 2) [_bounds[k], _bounds[k + 1]],
  ]);

  /// Parse the [toJson] format. Malformed input yields an empty list —
  /// including ranges that are empty, inverted, overlapping or out of order:
  /// those violate the sorted-disjoint invariant [contains] binary-searches
  /// on, so a corrupt document degrades to "no gaps" rather than a corrupt
  /// list. (Adjacent ranges are valid and merge on [append].)
  factory GapList.fromJson(String json) {
    final gaps = GapList();
    try {
      final List<dynamic> parsed = jsonDecode(json);
      var lastEnd = -1;
      for (final pair in parsed) {
        final start = (pair[0] as num).toInt();
        final end = (pair[1] as num).toInt();
        if (end <= start || start < lastEnd) {
          throw const FormatException('gap ranges must be increasing');
        }
        gaps.append(start, end);
        lastEnd = end;
      }
    } catch (_) {
      gaps.clear();
    }
    return gaps;
  }
}
