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

/// `#123` → `123`, `lc-101` → `LC-101`; anything else is not a card ID.
String? normalizeCardId(String raw) {
  var id = raw.trim();
  if (id.startsWith('#')) id = id.substring(1);
  id = id.toUpperCase();
  return _numericId.hasMatch(id) || _keyedId.hasMatch(id) ? id : null;
}

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
