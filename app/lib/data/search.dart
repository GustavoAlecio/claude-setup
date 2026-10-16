/// Case- and accent-insensitive "contains" over [fields]; an empty [query] matches everything.
bool matchesQuery(Iterable<String> fields, String query) {
  final q = foldForSearch(query.trim());
  if (q.isEmpty) return true;
  return fields.any((field) => foldForSearch(field).contains(q));
}

const _from = 'áàâãäéèêëíìîïóòôõöúùûüç';
const _to = 'aaaaaeeeeiiiiooooouuuuc';

String foldForSearch(String s) {
  final out = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = _from.indexOf(ch);
    out.write(i < 0 ? ch : _to[i]);
  }
  return out.toString();
}
