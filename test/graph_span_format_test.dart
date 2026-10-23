import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph_components.dart';

void main() {
  group('formatWindowSpan', () {
    test('sub-second spans print as whole milliseconds', () {
      expect(formatWindowSpan(0.5), '500 ms');
      expect(formatWindowSpan(0.05), '50 ms');
    });

    test('whole seconds drop the decimal', () {
      expect(formatWindowSpan(5), '5 s');
      expect(formatWindowSpan(30), '30 s');
      expect(formatWindowSpan(10.0), '10 s');
    });

    test('fractional seconds keep one decimal', () {
      expect(formatWindowSpan(12.471), '12.5 s');
    });

    test('minute spans print as m:ss', () {
      expect(formatWindowSpan(60), '1:00');
      expect(formatWindowSpan(125), '2:05');
      expect(formatWindowSpan(3599), '59:59');
    });

    test('fractional minute spans round to the second', () {
      expect(formatWindowSpan(125.7), '2:06');
    });

    test('spans that round up into the next unit print in that unit', () {
      // 0.9997 s would print "1000 ms" and 59.97 s would print "60.0 s"; each
      // rolls over on the rounded value instead.
      expect(formatWindowSpan(0.9997), '1 s');
      expect(formatWindowSpan(0.9994), '999 ms');
      expect(formatWindowSpan(59.97), '1:00');
      expect(formatWindowSpan(59.9), '59.9 s');
    });

    test('hour spans fold hours like the axis ticks', () {
      expect(formatWindowSpan(3600), '1:00:00');
      expect(formatWindowSpan(3661), '1:01:01');
      expect(formatWindowSpan(36067), '10:01:07');
    });
  });
}
