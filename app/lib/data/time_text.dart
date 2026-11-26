/// "agora" < 60 s, then minutes, hours and days (< 30 d), then `dd/MM/aaaa`; `null` is "—".
String relativeAge(DateTime? then, DateTime now) {
  if (then == null) return '—';
  final diff = now.difference(then);
  if (diff.inSeconds < 60) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'há ${diff.inHours} h';
  if (diff.inDays < 30) return 'há ${diff.inDays} d';
  final d = then.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}
