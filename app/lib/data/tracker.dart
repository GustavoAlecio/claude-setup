import '../engine/engine_config.dart';

/// A card a cycle or a PR is linked to: `tracker` in `current.json` and `prs.json`, written by `/kickoff` and
/// `pr-registry.sh`.
class CardRef {
  const CardRef({required this.kind, required this.id, this.url});

  final TrackerKind kind;
  final String id;
  final String? url;

  /// ADO keeps the `AB#` of its GitHub integration; Jira and Linear keys already name their project.
  String get label => kind == TrackerKind.ado ? 'AB#$id' : id;

  /// `null` for anything that is not a map with a known `kind` and a non-empty `id` (an int `id` is accepted).
  static CardRef? fromRaw(Object? raw) {
    if (raw is! Map) return null;
    final kind = TrackerKind.parse(raw['kind']);
    final id = switch (raw['id']) {
      final int n => '$n',
      final String s when s.isNotEmpty => s,
      _ => null,
    };
    if (kind == null || id == null) return null;
    final url = raw['url'];
    return CardRef(kind: kind, id: id, url: url is String && url.isNotEmpty ? url : null);
  }
}

/// `tracker` of a `current.json`: the card's label, `manual` for a cycle without a card, `null` otherwise.
String? cycleTrackerLabel(Object? raw) =>
    raw is Map && raw['kind'] == 'manual' ? 'manual' : CardRef.fromRaw(raw)?.label;
