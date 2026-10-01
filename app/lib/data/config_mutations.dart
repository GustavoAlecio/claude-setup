import 'dart:convert';

import '../engine/engine_config.dart';
import 'models.dart';
import 'orgs.dart';

/// Pure edit over the decoded `.dashboard.json`. The input is never mutated; unknown keys and their
/// order survive, new keys go at the end. Throws [ConfigValidationException] on a rejected edit.
typedef ConfigMutation = Map<String, dynamic> Function(Map<String, dynamic> raw);

class ConfigValidationException implements Exception {
  const ConfigValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A rejected or failed `.dashboard.json` write; [message] is shown inline.
class ConfigWriteException implements Exception {
  const ConfigWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Applies [mutation] to [raw]; `null` when nothing changed (the caller must not write).
/// A [ConfigValidationException] surfaces as [ConfigWriteException] so callers handle one type.
Map<String, dynamic>? applyConfigMutation(Map<String, dynamic> raw, ConfigMutation mutation) {
  final Map<String, dynamic> out;
  try {
    out = mutation(raw);
  } on ConfigValidationException catch (e) {
    throw ConfigWriteException(e.message);
  }
  // Decoded JSON keeps key order, so equal encodings mean the same document in the same order.
  return jsonEncode(out) == jsonEncode(raw) ? null : out;
}

/// Appends the org and opens the app in it (`lastOrg`). [permissionMode] `null` inherits the global mode.
ConfigMutation createOrg(String name, List<String> roots, {OrgGithub? github, PermissionMode? permissionMode}) =>
    (raw) {
      final current = DashboardConfig.fromMap(raw);
      _check(validateOrgs([...current.orgs, OrgConfig(name: name, roots: roots, github: github)]));
      final out = _copy(raw);
      out['orgs'] = [
        ..._list(raw['orgs']),
        {'name': name, 'roots': roots, 'github': ?github?.toRaw(), 'permissionMode': ?permissionMode?.wire},
      ];
      out['lastOrg'] = name;
      return out;
    };

/// Global `permissionMode`; written even when it equals the default, so the choice survives a default change.
ConfigMutation setGlobalPermissionMode(PermissionMode mode) =>
    (raw) => _copy(raw)..['permissionMode'] = mode.wire;

/// Replaces the org list. [renames] maps old name → new name so `projects[].org` and `lastOrg` follow;
/// projects of a removed org lose their explicit `org` and fall back to the root rule.
ConfigMutation saveOrgs(List<OrgConfig> orgs, {Map<String, String> renames = const {}}) => (raw) {
  _check(validateOrgs(orgs));
  final kept = {for (final o in orgs) o.name};
  String? follow(String? org) {
    if (org == null) return null;
    final renamed = renames[org] ?? org;
    return kept.contains(renamed) || renamed == kNoOrg ? renamed : null;
  }

  final previous = <String, Map<String, dynamic>>{};
  for (final e in _list(raw['orgs'])) {
    if (e is Map && e['name'] is String) previous[renames[e['name']] ?? e['name'] as String] = _map(e);
  }
  final out = _copy(raw);
  out['orgs'] = [for (final o in orgs) _orgEntry(previous[o.name], o)];
  out['projects'] = [
    for (final p in _list(raw['projects']))
      if (p is Map && p['org'] is String) _withOrg(_map(p), follow(p['org'] as String)) else _clone(p),
  ];
  if (raw['projects'] == null) out.remove('projects');
  final last = follow(raw['lastOrg'] is String ? raw['lastOrg'] as String : null);
  if (last == null) {
    out.remove('lastOrg');
  } else {
    out['lastOrg'] = last;
  }
  return out;
};

/// Edits one org by name against the freshly read document, so concurrent saves of other orgs are kept.
ConfigMutation updateOrg(String oldName, OrgConfig draft) => (raw) {
  final orgs = DashboardConfig.fromMap(raw).orgs;
  if (!orgs.any((o) => o.name == oldName)) {
    throw ConfigValidationException('org desconhecida: "$oldName"');
  }
  return saveOrgs([
    for (final o in orgs) o.name == oldName ? draft : o,
  ], renames: oldName == draft.name ? const {} : {oldName: draft.name})(raw);
};

ConfigMutation addOrg(OrgConfig draft) =>
    (raw) => saveOrgs([...DashboardConfig.fromMap(raw).orgs, draft])(raw);

ConfigMutation removeOrg(String name) => (raw) {
  final orgs = DashboardConfig.fromMap(raw).orgs.where((o) => o.name != name).toList();
  return saveOrgs(orgs)(raw);
};

ConfigMutation setLastOrg(String name) => (raw) {
  final current = DashboardConfig.fromMap(raw);
  if (name != kNoOrg && !current.orgs.any((o) => o.name == name)) {
    throw ConfigValidationException('org desconhecida: "$name"');
  }
  return _copy(raw)..['lastOrg'] = name;
};

/// Registers an existing repo; a project already listed with a path, by name or path, is rejected.
/// An entry with the same name but no path (left by [setProjectOrg]) gets [path] and keeps its `org`
/// unless [org] is given. Clears `hidden`.
ConfigMutation addProject({required String name, required String path, String? org}) => (raw) {
  final current = DashboardConfig.fromMap(raw);
  if (current.projects.any((p) => p.name == name && p.path != null)) {
    throw ConfigValidationException('projeto já adicionado: "$name"');
  }
  if (current.projects.any((p) => p.path != null && normalizePath(p.path!) == normalizePath(path))) {
    throw ConfigValidationException('pasta já adicionada: $path');
  }
  _checkOrg(current, org);
  final out = _copy(raw);
  final projects = <Object?>[];
  var merged = false;
  for (final p in _list(raw['projects'])) {
    if (!merged && p is Map && p['name'] == name) {
      merged = true;
      final entry = _map(p)..['path'] = path;
      projects.add(org == null ? entry : _withOrg(entry, org));
    } else {
      projects.add(_clone(p));
    }
  }
  if (!merged) projects.add({'name': name, 'path': path, 'org': ?org});
  out['projects'] = projects;
  _setHidden(out, raw, name, hidden: false);
  return out;
};

/// `org == null` drops the explicit assignment. A project not yet in `projects` gets an entry with [path].
ConfigMutation setProjectOrg(String name, String? org, {String? path}) => (raw) {
  final current = DashboardConfig.fromMap(raw);
  _checkOrg(current, org);
  final out = _copy(raw);
  final projects = <Object?>[];
  var found = false;
  for (final p in _list(raw['projects'])) {
    if (!found && p is Map && p['name'] == name) {
      found = true;
      projects.add(_withOrg(_map(p), org));
    } else {
      projects.add(_clone(p));
    }
  }
  if (!found) projects.add({'name': name, 'path': ?path, 'org': ?org});
  out['projects'] = projects;
  return out;
};

ConfigMutation hideProject(String name) =>
    (raw) => _setHidden(_copy(raw), raw, name, hidden: true);

ConfigMutation unhideProject(String name) =>
    (raw) => _setHidden(_copy(raw), raw, name, hidden: false);

Map<String, dynamic> _setHidden(
  Map<String, dynamic> out,
  Map<String, dynamic> raw,
  String name, {
  required bool hidden,
}) {
  final list = [
    for (final h in _list(raw['hidden']))
      if (h != name) _clone(h),
    if (hidden) name,
  ];
  if (list.isEmpty && raw['hidden'] == null) {
    out.remove('hidden');
  } else {
    out['hidden'] = list;
  }
  return out;
}

/// `github` is rewritten only when it differs from what [previous] parses to, so an untouched org keeps its raw
/// entry (unknown keys and dropped owners included); a rewrite still keeps unknown keys inside `github`.
/// `permissionMode` follows the same rule: an invalid raw value parses to inherit and survives until the org gets a
/// mode; inheriting over a valid mode removes the key, never writing `null`.
Map<String, dynamic> _orgEntry(Map<String, dynamic>? previous, OrgConfig org) {
  final entry = {...?previous, 'name': org.name, 'roots': org.roots};
  final github = org.github;
  final before = previous?['github'];
  if (github != null && github != OrgGithub.fromRaw(before)) {
    entry['github'] = {if (before is Map<String, dynamic>) ...before, ...github.toRaw()};
  }
  final mode = org.permissionMode;
  if (mode != PermissionMode.parse(previous?['permissionMode'])) {
    if (mode == null) {
      entry.remove('permissionMode');
    } else {
      entry['permissionMode'] = mode.wire;
    }
  }
  return entry;
}

Map<String, dynamic> _withOrg(Map<String, dynamic> entry, String? org) {
  if (org == null) {
    entry.remove('org');
  } else {
    entry['org'] = org;
  }
  return entry;
}

void _checkOrg(DashboardConfig current, String? org) {
  if (org != null && org != kNoOrg && !current.orgs.any((o) => o.name == org)) {
    throw ConfigValidationException('org desconhecida: "$org"');
  }
}

void _check(String? error) {
  if (error != null) throw ConfigValidationException(error);
}

List<Object?> _list(Object? v) => v is List ? v : const [];

Map<String, dynamic> _map(Map<Object?, Object?> m) => {
  for (final e in m.entries)
    if (e.key is String) e.key as String: _clone(e.value),
};

Map<String, dynamic> _copy(Map<String, dynamic> raw) => _map(raw);

Object? _clone(Object? v) => switch (v) {
  Map() => _map(v),
  List() => [for (final e in v) _clone(e)],
  _ => v,
};
