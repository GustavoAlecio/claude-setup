import 'package:claude_flow/data/session_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agy quota: title, reset in days and hours', () {
    final f = describeFailure('error: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 159h3m32s.');
    expect(f.title, 'Cota do modelo esgotada');
    expect(f.resets, 'em 6d 15h');
    expect(f.hint, isNotNull);
  });

  test('agy quota under a day', () {
    expect(describeFailure('RESOURCE_EXHAUSTED: quota. Resets in 2h5m1s.').resets, 'em 2h 5min');
    expect(describeFailure('RESOURCE_EXHAUSTED: quota. Resets in 40s.').resets, 'em 1min');
  });

  test('Claude usage limit with epoch: clock time today', () {
    final now = DateTime(2026, 10, 7, 9);
    final at = DateTime(2026, 10, 7, 15, 30);
    final f = describeFailure('Claude AI usage limit reached|${at.millisecondsSinceEpoch ~/ 1000}', now: now);
    expect(f.title, 'Limite de uso da assinatura atingido');
    expect(f.resets, 'às 15:30');
  });

  test('Claude limit with text reset', () {
    final f = describeFailure('5-hour limit reached ∙ resets 3pm');
    expect(f.title, 'Limite de uso da assinatura atingido');
    expect(f.resets, '3pm');
  });

  test('rate limit, auth, max turns, unknown and empty', () {
    expect(describeFailure('API Error: 529 overloaded_error').title, 'Provider sobrecarregado agora');
    expect(describeFailure('401 Unauthorized').title, 'Login do provider expirou');
    expect(describeFailure('error_max_turns').title, 'Limite de turnos atingido');
    expect(describeFailure('error_during_execution').title, 'A resposta falhou');
    expect(describeFailure(null).detail, 'O provider não informou o motivo.');
  });
}
