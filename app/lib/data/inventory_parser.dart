import 'dart:convert';

import 'inventory_models.dart';

const _knownKeys = {'name', 'description', 'model', 'tools', 'id', 'title', 'status'};

final _keyLine = RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$');
final _blockIndicator = RegExp(r'^[>|]-?$');

String _basename(String path) => path.split('/').last;

String _unreadable(String path, String reason) => 'não foi possível ler ${_basename(path)}: $reason';

({List<String> lines, int end})? _frontmatterBounds(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  if (lines.isEmpty || lines.first.trimRight() != '---') return null;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trimRight() == '---') return (lines: lines, end: i);
  }
  return (lines: lines, end: -1);
}

/// Subconjunto de YAML aceito pelas skills/agentes/ADRs. Chaves desconhecidas são ignoradas por inteiro
/// (inclusive o valor); chaves conhecidas fora das formas (a)-(e) viram `error`.
FrontmatterResult parseFrontmatter(String raw) {
  final bounds = _frontmatterBounds(raw);
  if (bounds == null) return const FrontmatterResult();
  if (bounds.end < 0) return const FrontmatterResult(error: 'frontmatter sem fechamento ---');
  final lines = bounds.lines.sublist(1, bounds.end);
  final fields = <String, Object>{};
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
      i++;
      continue;
    }
    final m = line.startsWith(' ') || line.startsWith('\t') ? null : _keyLine.firstMatch(line.trimRight());
    if (m == null) return FrontmatterResult(error: 'linha inválida no frontmatter: "${line.trim()}"');
    final key = m.group(1)!;
    final value = (m.group(2) ?? '').trim();
    i++;
    final continuation = <String>[];
    while (i < lines.length && (lines[i].trim().isEmpty || lines[i].startsWith(' ') || lines[i].startsWith('\t'))) {
      continuation.add(lines[i]);
      i++;
    }
    while (continuation.isNotEmpty && continuation.last.trim().isEmpty) {
      continuation.removeLast();
    }
    if (!_knownKeys.contains(key)) continue;
    final parsed = _scalar(key, value, continuation);
    if (parsed.error != null) return FrontmatterResult(error: parsed.error);
    final text = parsed.value!;
    fields[key] = key == 'tools' ? _splitTools(text) : text;
  }
  return FrontmatterResult(fields: fields);
}

({String? value, String? error}) _scalar(String key, String value, List<String> continuation) {
  if (_blockIndicator.hasMatch(value)) {
    final body = continuation.where((l) => l.trim().isNotEmpty).toList();
    if (body.isEmpty) return (value: '', error: null);
    final indent = body.map((l) => l.length - l.trimLeft().length).reduce((a, b) => a < b ? a : b);
    final text = body.map((l) => l.substring(indent).trimRight());
    return (value: value.startsWith('>') ? text.join(' ') : text.join('\n'), error: null);
  }
  if (continuation.any((l) => l.trim().isNotEmpty)) {
    return (value: null, error: 'valor multilinha não suportado em "$key"');
  }
  if (value.startsWith('"')) return _quoted(key, value, '"');
  if (value.startsWith("'")) return _quoted(key, value, "'");
  if (value.startsWith('{') || (value.startsWith('[') && key != 'tools')) {
    return (value: null, error: 'valor não suportado em "$key"');
  }
  return (value: value, error: null);
}

({String? value, String? error}) _quoted(String key, String value, String quote) {
  final out = StringBuffer();
  var i = 1;
  while (i < value.length) {
    final c = value[i];
    if (quote == '"' && c == r'\') {
      if (i + 1 >= value.length) break;
      final n = value[i + 1];
      out.write(switch (n) {
        'n' => '\n',
        't' => '\t',
        _ => n == '"' || n == r'\' ? n : '$c$n',
      });
      i += 2;
    } else if (c == quote) {
      if (quote == "'" && i + 1 < value.length && value[i + 1] == "'") {
        out.write("'");
        i += 2;
        continue;
      }
      final rest = value.substring(i + 1).trim();
      if (rest.isEmpty || rest.startsWith('#')) return (value: out.toString(), error: null);
      return (value: null, error: 'texto após aspas em "$key"');
    } else {
      out.write(c);
      i++;
    }
  }
  return (value: null, error: 'aspas sem fechamento em "$key"');
}

List<String> _splitTools(String text) {
  var s = text.trim();
  if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
  return s.split(',').map((t) => t.trim().replaceAll(RegExp('^["\']|["\']\$'), '')).where((t) => t.isNotEmpty).toList();
}

/// Skill ou agente: `fallbackName` (nome do diretório/arquivo) vale quando o frontmatter não traz `name`.
InventoryItem parseInventoryItem(String raw, {required String path, required String fallbackName}) {
  final fm = parseFrontmatter(raw);
  if (fm.error != null) {
    return InventoryItem(name: fallbackName, path: path, error: _unreadable(path, fm.error!));
  }
  final f = fm.fields;
  final name = f['name'];
  final model = f['model'];
  final tools = f['tools'];
  return InventoryItem(
    name: name is String && name.isNotEmpty ? name : fallbackName,
    path: path,
    description: f['description'] is String ? f['description'] as String : '',
    model: model is String && model.isNotEmpty ? model : null,
    tools: tools is List<String> ? tools : const [],
  );
}

/// `null` quando o JSON é inválido ou não é um objeto.
StackInfo? parseStack(String raw, {required String fallbackName}) {
  final Object? d;
  try {
    d = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (d is! Map) return null;
  final reviewers = d['g1_reviewers'];
  return StackInfo(
    name: d['name'] is String ? d['name'] as String : fallbackName,
    g1Reviewers: reviewers is List ? reviewers.whereType<String>().toList() : const [],
    g2Agent: d['g2_agent'] is String ? d['g2_agent'] as String : null,
    rulesDir: d['rules_dir'] is String ? d['rules_dir'] as String : null,
    adrDir: d['adr_dir'] is String ? d['adr_dir'] as String : null,
  );
}

AdrEntry parseAdr(String raw, {required String path}) {
  final fm = parseFrontmatter(raw);
  final f = fm.fields;
  final id = f['id'];
  final title = f['title'];
  final status = f['status'];
  final String? error = fm.error != null
      ? _unreadable(path, fm.error!)
      : (id is! String || id.isEmpty || title is! String || status is! String)
      ? _unreadable(path, 'frontmatter sem id, title ou status')
      : null;
  return AdrEntry(
    id: id is String ? id : '',
    title: title is String ? title : '',
    status: status is String ? status : '',
    path: path,
    error: error,
  );
}

/// Resumo = primeira linha não vazia após o frontmatter e o `# título`. O conteúdo do frontmatter
/// não é interpretado: rules usam `paths: [...]`, fora do subconjunto.
RuleEntry parseRuleSummary(String raw, {required String path}) {
  final name = _basename(path).replaceFirst(RegExp(r'\.md$'), '');
  final bounds = _frontmatterBounds(raw);
  if (bounds != null && bounds.end < 0) {
    return RuleEntry(name: name, path: path, error: _unreadable(path, 'frontmatter sem fechamento ---'));
  }
  final lines = bounds == null ? raw.replaceAll('\r\n', '\n').split('\n') : bounds.lines.sublist(bounds.end + 1);
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  if (i < lines.length && lines[i].startsWith('# ')) i++;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  return RuleEntry(name: name, path: path, summary: i < lines.length ? lines[i].trim() : '');
}

List<String> parseLessons(String raw) => raw
    .replaceAll('\r\n', '\n')
    .split('\n')
    .where((l) => l.startsWith('- '))
    .map((l) => l.substring(2).trim())
    .where((l) => l.isNotEmpty)
    .toList();

/// Primeira frase: até o primeiro ". " seguido de maiúscula fora de parênteses (e que não siga "ex"/"vs"),
/// ou o texto todo, numa linha só.
String firstSentence(String text) {
  final s = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  var depth = 0;
  for (var i = 0; i < s.length - 2; i++) {
    final c = s[i];
    if (c == '(') depth++;
    if (c == ')' && depth > 0) depth--;
    if (c != '.' || depth > 0 || s[i + 1] != ' ') continue;
    final next = s[i + 2];
    if (next.toLowerCase() == next || next.toUpperCase() != next) continue;
    final word = RegExp(r'([A-Za-zÀ-ÿ]+)$').firstMatch(s.substring(0, i))?.group(1)?.toLowerCase();
    if (word == 'ex' || word == 'vs') continue;
    return s.substring(0, i + 1);
  }
  return s;
}

Routing parseRouting(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const Routing(error: 'routing.json não é um objeto');
    final bands = <RoutingBand>[];
    final rawBands = decoded['bands'];
    if (rawBands != null) {
      if (rawBands is! List) return const Routing(error: 'bands não é uma lista');
      for (final b in rawBands) {
        if (b is! Map) return const Routing(error: 'band inválida');
        bands.add(
          RoutingBand(
            complexity: b['complexity'] as String,
            risk: b['risk'] as String,
            n: b['n'] as int,
            passTier0: b['pass_tier0'] as int,
            escalated: b['escalated'] as int,
            blocked: b['blocked'] as int,
            attemptsPerTask: (b['attempts_per_task'] as num).toDouble(),
            finalTiers: {
              for (final e in ((b['final_tiers'] as Map?) ?? const {}).entries) e.key as String: e.value as int,
            },
          ),
        );
      }
    }
    final overrides = <String, String>{};
    final rawOverrides = decoded['overrides'];
    if (rawOverrides != null) {
      if (rawOverrides is! Map) return const Routing(error: 'overrides não é um objeto');
      for (final e in rawOverrides.entries) {
        final tier0 = e.value is Map ? (e.value as Map)['tier0'] : null;
        if (tier0 is String) overrides[e.key as String] = tier0;
      }
    }
    return Routing(bands: bands, overrides: overrides);
  } on FormatException catch (e) {
    return Routing(error: 'routing.json inválido: ${e.message}');
  } on TypeError {
    return const Routing(error: 'routing.json com campo de tipo inesperado');
  }
}

final _hex4 = RegExp(r'^[0-9A-Fa-f]{4}$');

class _JsError implements Exception {
  _JsError(this.message);
  final String message;
}

/// Literal JS: objetos (chave sem aspas ou string), arrays, strings, números, true/false/null,
/// comentários e vírgula sobrando. Template string, spread e identificador como valor falham.
class _JsLiteral {
  _JsLiteral(this.s, this.i);

  final String s;
  int i;

  Never _fail(String msg) => throw _JsError('$msg (posição $i)');

  void skip() {
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
        i++;
      } else if (s.startsWith('//', i)) {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (s.startsWith('/*', i)) {
        final end = s.indexOf('*/', i + 2);
        if (end < 0) _fail('comentário sem fechamento');
        i = end + 2;
      } else {
        break;
      }
    }
  }

  Object? value() {
    skip();
    if (i >= s.length) _fail('fim inesperado');
    final c = s[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"' || c == "'") return _string();
    if (c == '`') _fail('template string não suportada');
    if (s.startsWith('...', i)) _fail('spread não suportado');
    final word = RegExp(r'-?[A-Za-z0-9_.$]+').matchAsPrefix(s, i)?.group(0);
    if (word == null) _fail('token inesperado "$c"');
    i += word.length;
    return switch (word) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => num.tryParse(word) ?? _fail('identificador "$word" não suportado'),
    };
  }

  Map<String, Object?> _object() {
    i++;
    final out = <String, Object?>{};
    while (true) {
      skip();
      if (i >= s.length) _fail('objeto sem fechamento');
      if (s[i] == '}') {
        i++;
        return out;
      }
      if (s.startsWith('...', i)) _fail('spread não suportado');
      final String key;
      if (s[i] == '"' || s[i] == "'") {
        key = _string();
      } else {
        final w = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').matchAsPrefix(s, i)?.group(0);
        if (w == null) _fail('chave inválida');
        key = w;
        i += w.length;
      }
      skip();
      if (i >= s.length || s[i] != ':') _fail('esperava ":" após a chave "$key"');
      i++;
      out[key] = value();
      skip();
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i >= s.length || s[i] != '}') {
        _fail('esperava "," ou "}"');
      }
    }
  }

  List<Object?> _array() {
    i++;
    final out = <Object?>[];
    while (true) {
      skip();
      if (i >= s.length) _fail('array sem fechamento');
      if (s[i] == ']') {
        i++;
        return out;
      }
      out.add(value());
      skip();
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i >= s.length || s[i] != ']') {
        _fail('esperava "," ou "]"');
      }
    }
  }

  String _string() {
    final quote = s[i++];
    final out = StringBuffer();
    while (i < s.length) {
      final c = s[i];
      if (c == quote) {
        i++;
        return out.toString();
      }
      if (c == '\n') _fail('string com quebra de linha');
      if (c == r'\') {
        if (i + 1 >= s.length) break;
        final n = s[i + 1];
        i += 2;
        switch (n) {
          case 'n':
            out.write('\n');
          case 't':
            out.write('\t');
          case 'u':
            final digits = i + 4 <= s.length ? s.substring(i, i + 4) : '';
            if (!_hex4.hasMatch(digits)) _fail('escape \\u inválido');
            out.writeCharCode(int.parse(digits, radix: 16));
            i += 4;
          default:
            out.write(n);
        }
        continue;
      }
      out.write(c);
      i++;
    }
    _fail('string sem fechamento');
  }
}

WorkflowMeta parseWorkflowMeta(String source, {String fallbackName = ''}) {
  WorkflowMeta fail(String msg) => WorkflowMeta(name: fallbackName, error: msg);
  final start = RegExp(r'export\s+const\s+meta\s*=\s*').firstMatch(source);
  if (start == null) return fail('export const meta não encontrado');
  try {
    final v = _JsLiteral(source, start.end).value();
    if (v is! Map<String, Object?>) return fail('meta não é um objeto');
    final phases = <WorkflowPhase>[];
    final rawPhases = v['phases'];
    if (rawPhases != null) {
      if (rawPhases is! List) return fail('phases não é uma lista');
      for (final p in rawPhases) {
        final title = p is Map ? p['title'] : null;
        if (title is! String) return fail('phase sem title');
        final detail = (p as Map)['detail'];
        phases.add(WorkflowPhase(title: title, detail: detail is String ? detail : ''));
      }
    }
    final name = v['name'];
    final description = v['description'];
    return WorkflowMeta(
      name: name is String && name.isNotEmpty ? name : fallbackName,
      description: description is String ? description : '',
      phases: phases,
    );
  } on _JsError catch (e) {
    return fail(e.message);
  } catch (e) {
    return fail('meta ilegível: $e');
  }
}

/// Lê `const LADDER|TIER0|BLOCKING = <literal>`; o literal pode ocupar várias linhas.
Ladder parseLadder(String source) {
  try {
    return _parseLadder(source);
  } catch (e) {
    return Ladder(error: 'smart-implement.js ilegível: $e');
  }
}

Ladder _parseLadder(String source) {
  String? error;
  Object? read(String name) {
    final m = RegExp('^const $name = ', multiLine: true).firstMatch(source);
    if (m == null) {
      error ??= '$name não encontrado';
      return null;
    }
    try {
      final lit = _JsLiteral(source, m.end);
      final v = lit.value();
      final eol = source.indexOf('\n', lit.i);
      final rest = source.substring(lit.i, eol < 0 ? source.length : eol).trim();
      if (rest.isNotEmpty && rest != ';' && !rest.startsWith('//')) {
        error ??= '$name: texto após o literal';
        return null;
      }
      return v;
    } on _JsError catch (e) {
      error ??= '$name: ${e.message}';
      return null;
    }
  }

  List<String> strings(Object? v, String name) {
    if (v is List && v.every((e) => e is String)) return v.cast<String>();
    if (v != null) error ??= '$name não é uma lista de strings';
    return const [];
  }

  final tiers = strings(read('LADDER'), 'LADDER');
  final rawTier0 = read('TIER0');
  final blocking = strings(read('BLOCKING'), 'BLOCKING');
  var tier0 = <String, String>{};
  if (rawTier0 is Map && rawTier0.values.every((e) => e is String)) {
    tier0 = rawTier0.cast<String, String>();
  } else if (rawTier0 != null) {
    error ??= 'TIER0 não é um mapa de strings';
  }
  return Ladder(tiers: tiers, tier0: tier0, blocking: blocking, error: error);
}
