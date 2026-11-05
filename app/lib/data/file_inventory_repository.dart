import 'dart:developer';
import 'dart:io';

import 'inventory_models.dart';
import 'inventory_parser.dart';
import 'inventory_repository.dart';
import 'models.dart';
import 'orgs.dart';

class FileInventoryRepository implements InventoryRepository {
  FileInventoryRepository(String claudeHome) : claudeHome = normalizePath(claudeHome);

  final String claudeHome;

  @override
  Future<Inventory> loadInventory() async {
    final workflows = await _workflows();
    final ladderFile = '$claudeHome/workflows/smart-implement.js';
    final ladderSource = await _read(ladderFile);
    return Inventory(
      claudeHome: claudeHome,
      skills: await _skills(),
      agents: await _agents(),
      workflows: workflows,
      stacks: await _stacks(),
      ladder: ladderSource.text == null
          ? Ladder(error: 'não foi possível ler smart-implement.js: ${ladderSource.error}')
          : parseLadder(ladderSource.text!),
    );
  }

  @override
  Future<ProjectInventory> loadProject(Project project) async {
    final stack = (await _stacks()).where((s) => s.name == project.stack).firstOrNull;
    final rulesDir = stack?.rulesDir ?? const StackInfo(name: '').rulesDir;
    final adrDir = stack?.adrDir ?? const StackInfo(name: '').adrDir;
    final path = project.path;

    final stateDir = '$claudeHome/projects/${project.name}';
    final lessons = await _read('$stateDir/lessons.md');
    final routing = await _read('$stateDir/routing.json');
    return ProjectInventory(
      rules: path == null ? const [] : await _rules('${normalizePath(path)}/$rulesDir'),
      adrs: path == null ? const [] : await _adrs('${normalizePath(path)}/$adrDir'),
      lessons: lessons.text == null ? const [] : parseLessons(lessons.text!),
      routing: routing.text != null
          ? parseRouting(routing.text!)
          : routing.missing
          ? const Routing()
          : Routing(error: 'não foi possível ler routing.json: ${routing.error}'),
    );
  }

  Future<List<InventoryItem>> _skills() async {
    final out = <InventoryItem>[];
    for (final dir in await _entries('$claudeHome/skills')) {
      final name = _basename(dir);
      if (!await FileSystemEntity.isDirectory(dir)) continue;
      final file = '$dir/SKILL.md';
      if (!await File(file).exists()) continue;
      out.add(await _item(file, name));
    }
    return out;
  }

  Future<List<InventoryItem>> _agents() async {
    final out = <InventoryItem>[];
    for (final file in await _files('$claudeHome/agents', '.md')) {
      out.add(await _item(file, _basename(file).replaceFirst(RegExp(r'\.md$'), '')));
    }
    return out;
  }

  Future<InventoryItem> _item(String file, String fallbackName) async {
    final read = await _read(file);
    if (read.text == null) {
      return InventoryItem(name: fallbackName, path: file, error: _unreadable(file, read.error));
    }
    return parseInventoryItem(read.text!, path: file, fallbackName: fallbackName);
  }

  Future<List<WorkflowEntry>> _workflows() async {
    final out = <WorkflowEntry>[];
    for (final file in await _files('$claudeHome/workflows', '.js')) {
      final name = _basename(file).replaceFirst(RegExp(r'\.js$'), '');
      final read = await _read(file);
      out.add(
        WorkflowEntry(
          path: file,
          meta: read.text == null
              ? WorkflowMeta(name: name, error: _unreadable(file, read.error))
              : parseWorkflowMeta(read.text!, fallbackName: name),
        ),
      );
    }
    return out;
  }

  Future<List<StackInfo>> _stacks() async {
    final out = <StackInfo>[];
    for (final file in await _files('$claudeHome/stacks', '.json')) {
      final read = await _read(file);
      if (read.text == null) continue;
      final stack = parseStack(read.text!, fallbackName: _basename(file).replaceFirst(RegExp(r'\.json$'), ''));
      if (stack == null) {
        log('invalid stack $file', name: 'file_inventory_repository');
      } else {
        out.add(stack);
      }
    }
    return out;
  }

  Future<List<RuleEntry>> _rules(String dir) async {
    final out = <RuleEntry>[];
    for (final file in await _files(dir, '.md')) {
      final read = await _read(file);
      out.add(
        read.text == null
            ? RuleEntry(
                name: _basename(file).replaceFirst(RegExp(r'\.md$'), ''),
                path: file,
                error: _unreadable(file, read.error),
              )
            : parseRuleSummary(read.text!, path: file),
      );
    }
    return out;
  }

  Future<List<AdrEntry>> _adrs(String dir) async {
    final out = <AdrEntry>[];
    for (final file in await _files(dir, '.md')) {
      if (!RegExp(r'^[0-9]').hasMatch(_basename(file))) continue;
      final read = await _read(file);
      out.add(
        read.text == null
            ? AdrEntry(id: '', title: '', status: '', path: file, error: _unreadable(file, read.error))
            : parseAdr(read.text!, path: file),
      );
    }
    return out;
  }

  /// Sorted direct children; empty when [dir] is missing or unreadable.
  Future<List<String>> _entries(String dir) async {
    try {
      final out = [for (final e in await Directory(dir).list().toList()) e.path]..sort();
      return out;
    } on FileSystemException {
      return const [];
    }
  }

  Future<List<String>> _files(String dir, String ext) async {
    final out = <String>[];
    for (final path in await _entries(dir)) {
      if (path.endsWith(ext) && await FileSystemEntity.isFile(path)) out.add(path);
    }
    return out;
  }

  Future<({String? text, String? error, bool missing})> _read(String path) async {
    try {
      return (text: await File(path).readAsString(), error: null, missing: false);
    } on PathNotFoundException {
      return (text: null, error: 'arquivo ausente', missing: true);
    } on FileSystemException catch (e) {
      return (text: null, error: e.osError?.message ?? e.message, missing: false);
    } on FormatException catch (e) {
      return (text: null, error: e.message, missing: false);
    }
  }

  static String _basename(String path) => path.split('/').last;

  static String _unreadable(String path, String? reason) => 'não foi possível ler ${_basename(path)}: $reason';
}
