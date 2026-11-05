class InventoryItem {
  const InventoryItem({
    required this.name,
    required this.path,
    this.description = '',
    this.model,
    this.tools = const [],
    this.error,
  });

  final String name;
  final String path;
  final String description;
  final String? model;
  final List<String> tools;
  final String? error;
}

class WorkflowPhase {
  const WorkflowPhase({required this.title, this.detail = ''});

  final String title;
  final String detail;
}

class WorkflowMeta {
  const WorkflowMeta({required this.name, this.description = '', this.phases = const [], this.error});

  final String name;
  final String description;
  final List<WorkflowPhase> phases;
  final String? error;
}

class Ladder {
  const Ladder({this.tiers = const [], this.tier0 = const {}, this.blocking = const [], this.error});

  final List<String> tiers;
  final Map<String, String> tier0;
  final List<String> blocking;
  final String? error;
}

class StackInfo {
  const StackInfo({required this.name, this.g1Reviewers = const [], this.g2Agent, String? rulesDir, String? adrDir})
    : rulesDir = rulesDir ?? '.claude/rules',
      adrDir = adrDir ?? 'docs/adr';

  final String name;
  final List<String> g1Reviewers;
  final String? g2Agent;
  final String rulesDir;
  final String adrDir;
}

class AdrEntry {
  const AdrEntry({
    required this.id,
    required this.title,
    required this.status,
    required this.path,
    this.date,
    this.affects = const [],
    this.supersedes = const [],
    this.supersededBy = const [],
    this.tags = const [],
    this.warning,
    this.error,
  });

  final String id;
  final String title;
  final String status;
  final String path;
  final String? date;
  final List<String> affects;
  final List<String> supersedes;
  final List<String> supersededBy;
  final List<String> tags;
  final String? warning;
  final String? error;

  AdrEntry withError(String error) => AdrEntry(
    id: id,
    title: title,
    status: status,
    path: path,
    date: date,
    affects: affects,
    supersedes: supersedes,
    supersededBy: supersededBy,
    tags: tags,
    error: error,
  );
}

class AdrChainItem {
  const AdrChainItem({required this.id, this.entry});

  final String id;

  /// `null` quando o id é citado por outro ADR mas não existe.
  final AdrEntry? entry;
}

class RuleEntry {
  const RuleEntry({required this.name, required this.path, this.summary = '', this.error});

  final String name;
  final String path;
  final String summary;
  final String? error;
}

class RoutingBand {
  const RoutingBand({
    required this.complexity,
    required this.risk,
    required this.n,
    required this.passTier0,
    required this.escalated,
    required this.blocked,
    required this.attemptsPerTask,
    this.finalTiers = const {},
  });

  final String complexity;
  final String risk;
  final int n;
  final int passTier0;
  final int escalated;
  final int blocked;
  final double attemptsPerTask;
  final Map<String, int> finalTiers;
}

class Routing {
  const Routing({this.bands = const [], this.overrides = const {}, this.error});

  final List<RoutingBand> bands;
  final Map<String, String> overrides;
  final String? error;
}

class FrontmatterResult {
  const FrontmatterResult({this.fields = const {}, this.error});

  final Map<String, Object> fields;
  final String? error;
}

class WorkflowEntry {
  const WorkflowEntry({required this.path, required this.meta});

  final String path;
  final WorkflowMeta meta;
}

class Inventory {
  const Inventory({
    required this.claudeHome,
    this.skills = const [],
    this.agents = const [],
    this.workflows = const [],
    this.stacks = const [],
    this.ladder = const Ladder(),
  });

  final String claudeHome;
  final List<InventoryItem> skills;
  final List<InventoryItem> agents;
  final List<WorkflowEntry> workflows;
  final List<StackInfo> stacks;
  final Ladder ladder;
}

class GitSubmodule {
  const GitSubmodule({required this.path, required this.url});

  final String path;
  final String url;
}

class ProjectInventory {
  const ProjectInventory({
    this.rules = const [],
    this.adrs = const [],
    this.lessons = const [],
    this.routing = const Routing(),
    this.adrSubmodule,
  });

  final List<RuleEntry> rules;
  final List<AdrEntry> adrs;
  final List<String> lessons;
  final Routing routing;

  /// Submódulo que contém o diretório de ADRs; `null` sem `.gitmodules` ou sem correspondência.
  final GitSubmodule? adrSubmodule;
}
