import '../engine/engine_config.dart';
import 'models.dart';

enum KickoffType { auto, feature, bug }

const kKickoffMaxChars = 20000;

/// Smart Flow skills, which run per project; the org palette leaves them out.
const kPipelineSkills = {
  'kickoff',
  'specify',
  'challenge-spec',
  'plan',
  'tasks',
  'implement',
  'verify',
  'complete',
  'fix',
  'auto',
  'status',
};

final _numericId = RegExp(r'^\d+$');
final _keyedId = RegExp(r'^[A-Z][A-Z0-9]*-\d+$');

/// A card ID of [tracker], as `bin/tracker.py` normalizes it: `#123` → `123` (ADO), `lc-101` → `LC-101`, and a
/// number gets the Jira project or Linear team prefix (`101` → `LC-101`). `null` when the ID does not fit.
String? normalizeCardId(String raw, OrgTracker tracker) {
  var id = raw.trim();
  if (id.startsWith('#')) id = id.substring(1);
  id = id.toUpperCase();
  if (tracker.kind == TrackerKind.ado) return _numericId.hasMatch(id) ? id : null;
  if (_keyedId.hasMatch(id)) return id;
  final prefix = tracker.keyPrefix;
  return _numericId.hasMatch(id) && prefix != null ? '${prefix.toUpperCase()}-$id' : null;
}

/// Example of the ID field: what an ID of [tracker] looks like.
String cardIdHint(OrgTracker tracker) => switch (tracker.kind) {
  TrackerKind.ado => '4821',
  _ => '${tracker.keyPrefix?.toUpperCase() ?? 'LC'}-101',
};

/// The skill reads everything after the first line break as the literal description, so it goes in
/// verbatim: no quoting, no escaping.
String kickoffCommand({String? id, String description = '', KickoffType type = KickoffType.auto}) {
  if (id != null) return '/kickoff $id';
  final flag = switch (type) {
    KickoffType.auto => '',
    KickoffType.feature => ' --feature',
    KickoffType.bug => ' --bug',
  };
  return '/kickoff --manual$flag\n\n$description';
}

String missingProjectPathError(Project project) => 'sem pasta para ${project.name}: adicione a pasta em Configurações';
