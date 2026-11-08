/// What a failed turn means for the user: a title in plain words, the provider's text as detail, and when the limit
/// resets (if the provider said so).
class SessionFailure {
  const SessionFailure(this.title, this.detail, {this.resets, this.hint});

  final String title;
  final String detail;
  final String? resets;

  /// What to do next, when it is not just "tentar de novo".
  final String? hint;
}

final _agyReset = RegExp(r'Resets in ((?:\d+h)?(?:\d+m)?(?:\d+s)?)', caseSensitive: false);
final _claudeEpoch = RegExp(r'limit reached\|(\d{9,})', caseSensitive: false);
final _claudeReset = RegExp(r'resets? (?:at )?([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?[^\n.|]*)', caseSensitive: false);

/// [raw] is the engine's text for a failed turn (the SDK subtype, agy's `short_error`, or the provider message).
SessionFailure describeFailure(String? raw, {DateTime? now}) {
  final text = (raw ?? '').trim();
  final detail = text.isEmpty ? 'O provider não informou o motivo.' : text;
  if (RegExp(r'RESOURCE_EXHAUSTED|quota', caseSensitive: false).hasMatch(text)) {
    final reset = _agyReset.firstMatch(text)?.group(1);
    return SessionFailure(
      'Cota do modelo esgotada',
      detail,
      resets: reset == null ? null : _duration(reset),
      hint: 'Troque para um modelo de outro grupo ou espere a renovação.',
    );
  }
  final epoch = _claudeEpoch.firstMatch(text)?.group(1);
  if (epoch != null || RegExp(r'usage limit|limit reached', caseSensitive: false).hasMatch(text)) {
    final at = epoch == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(epoch) * 1000);
    return SessionFailure(
      'Limite de uso da assinatura atingido',
      detail,
      resets: at != null ? _clock(at, now ?? DateTime.now()) : _claudeReset.firstMatch(text)?.group(1)?.trim(),
      hint: 'Troque para um modelo menor ou espere a renovação.',
    );
  }
  if (RegExp(r'rate.?limit|\b429\b|overloaded|\b529\b', caseSensitive: false).hasMatch(text)) {
    return SessionFailure('Provider sobrecarregado agora', detail, hint: 'Espere alguns segundos e tente de novo.');
  }
  if (RegExp(r'unauthori[sz]ed|\b401\b|authenticat|log ?in|credential', caseSensitive: false).hasMatch(text)) {
    return SessionFailure('Login do provider expirou', detail, hint: 'Entre de novo pela conta em Configurações.');
  }
  if (text == 'error_max_turns') {
    return SessionFailure('Limite de turnos atingido', detail, hint: 'Peça para continuar de onde parou.');
  }
  return SessionFailure('A resposta falhou', detail);
}

String _duration(String raw) {
  int part(String unit) => int.tryParse(RegExp('(\\d+)$unit').firstMatch(raw)?.group(1) ?? '') ?? 0;
  final hours = part('h');
  final minutes = part('m');
  if (hours >= 24) return 'em ${hours ~/ 24}d ${hours % 24}h';
  if (hours > 0) return 'em ${hours}h ${minutes}min';
  return 'em ${minutes < 1 ? 1 : minutes}min';
}

String _clock(DateTime at, DateTime now) {
  final local = at.toLocal();
  final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
  return sameDay
      ? 'às $hm'
      : 'em ${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} às $hm';
}
