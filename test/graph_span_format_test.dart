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

    test('hour spans fold hours like the axis ticks', () {
      expect(formatWindowSpan(3600), '1:00:00');
      expect(formatWindowSpan(3661), '1:01:01');
      expect(formatWindowSpan(36067), '10:01:07');
    });
  });
}
