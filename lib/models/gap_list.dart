import 'dart:convert';

/// Sorted, disjoint, half-open `[start, end)` ranges of missing samples, in
/// absolute sample indices. The ring buffer itself holds ordinary (held)
/// values inside gaps, so nothing else in the pipeline needs to know about
/// missing data.
class GapList {
  GapList();

  /// Flat `[start0, end0, start1, end1, ...]` storage, sorted and disjoint.
  final List<int> _bounds = [];

  bool get isEmpty => _bounds.isEmpty;

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

  /// Parse the [toJson] format. Strict: malformed input throws
  /// [FormatException] — a malformed document (including ranges that are
  /// empty, inverted, overlapping or out of order) violates the
  /// sorted-disjoint invariant [contains] binary-searches on, and silently
  /// degrading to "no gaps" would fabricate continuity (the caller decides
  /// the damage policy; see SessionStorage.loadSession). (Adjacent ranges
  /// are valid and merge on [append].)
  factory GapList.fromJson(String json) {
    final gaps = GapList();
    final parsed = jsonDecode(json);
    if (parsed is! List) {
      throw const FormatException('gap list must be a JSON list');
    }
    var lastEnd = 0;
    for (final pair in parsed) {
      if (pair is! List || pair.length != 2) {
        throw const FormatException('gap range must be a [start, end] pair');
      }
      final s = pair[0], e = pair[1];
      if (s is! num || e is! num) {
        throw const FormatException('gap bounds must be numbers');
      }
      final start = s.toInt(), end = e.toInt();
      if (start < 0 || end <= start || start < lastEnd) {
        throw const FormatException('gap ranges must be increasing');
      }
      gaps.append(start, end);
      lastEnd = end;
    }
    return gaps;
  }
}
