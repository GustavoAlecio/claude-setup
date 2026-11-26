import 'package:claude_flow/data/time_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('relativeAge', () {
    final now = DateTime.utc(2026, 3, 10, 12);

    test('null is a dash', () => expect(relativeAge(null, now), '—'));

    test('boundaries', () {
      expect(relativeAge(now.subtract(const Duration(seconds: 59)), now), 'agora');
      expect(relativeAge(now.add(const Duration(minutes: 5)), now), 'agora');
      expect(relativeAge(now.subtract(const Duration(seconds: 60)), now), 'há 1 min');
      expect(relativeAge(now.subtract(const Duration(minutes: 59, seconds: 59)), now), 'há 59 min');
      expect(relativeAge(now.subtract(const Duration(minutes: 60)), now), 'há 1 h');
      expect(relativeAge(now.subtract(const Duration(hours: 23, minutes: 59)), now), 'há 23 h');
      expect(relativeAge(now.subtract(const Duration(hours: 24)), now), 'há 1 d');
      expect(relativeAge(now.subtract(const Duration(days: 29, hours: 23)), now), 'há 29 d');
    });

    test('30 days or more is a date', () {
      final then = DateTime(2026, 2, 8, 12);
      final text = relativeAge(then, DateTime(2026, 3, 10, 12));
      expect(text, '08/02/2026');
    });
  });
}
