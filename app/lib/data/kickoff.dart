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

/// The command that starts a cycle from what the user typed: a lone card ID of [tracker] goes by the tracker form,
/// anything else is the manual description. `null` for blank text.
String? startCommand(String text, OrgTracker? tracker) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (tracker != null && !trimmed.contains(RegExp(r'\s'))) {
    final id = normalizeCardId(trimmed, tracker);
    if (id != null) return kickoffCommand(id: id);
  }
  return kickoffCommand(description: trimmed);
}

const _skillLabels = {
  'fix': 'Corrigir um bug sem abrir ciclo',
  'review': 'Revisar um PR',
  'pr-status': 'Ver como estão meus PRs',
  'pr-open': 'Abrir o PR desta branch',
  'status': 'Ver em que pé está o ciclo',
  'refine': 'Detalhar uma tarefa',
  'adr': 'Registrar uma decisão de arquitetura',
  'approve-review': 'Aprovar uma revisão local',
  'post-review': 'Publicar uma revisão no PR',
  'specify': 'Escrever a spec',
  'challenge-spec': 'Desafiar a spec antes do plano',
  'plan': 'Gerar o plano técnico',
  'tasks': 'Quebrar o plano em tasks',
  'implement': 'Implementar as tasks',
  'verify': 'Verificar o ciclo',
  'complete': 'Fechar o ciclo e abrir o PR',
  'discovery': 'Amadurecer uma ideia de produto',
  'orcamento': 'Gerar uma proposta comercial',
};

const _skillLabelMaxChars = 60;

final _stagePrefix = RegExp(
  r'^(Etapa \S+ do Fluxo Smart|Fluxo Review etapa \S+|Etapa final do Fluxo Smart)\s*—\s*',
  caseSensitive: false,
);

/// The palette's phrase for a skill: the known name's fixed text, otherwise the first sentence of its
/// [description] without the pipeline-stage prefix, capitalized and cut at a word within 60 characters.
String skillLabel(String name, String description) {
  final known = _skillLabels[name];
  if (known != null) return known;
  var text = description.trim().replaceFirst(_stagePrefix, '');
  final cuts = [text.indexOf('. '), text.indexOf('—'), text.indexOf(' - ')].where((i) => i >= 0);
  if (cuts.isNotEmpty) text = text.substring(0, cuts.reduce((a, b) => a < b ? a : b));
  text = text.trim();
  if (text.endsWith('.')) text = text.substring(0, text.length - 1).trimRight();
  if (text.isEmpty) return name;
  text = text[0].toUpperCase() + text.substring(1);
  if (text.length <= _skillLabelMaxChars) return text;
  final space = text.lastIndexOf(' ', _skillLabelMaxChars - 1);
  final end = space > 0 ? space : _skillLabelMaxChars - 1;
  return '${text.substring(0, end).trimRight()}…';
}

String pendingLine(int n) => switch (n) {
  0 => 'nada esperando você',
  _ => '$n esperando você',
};

String missingProjectPathError(Project project) => 'sem pasta para ${project.name}: adicione a pasta em Configurações';
