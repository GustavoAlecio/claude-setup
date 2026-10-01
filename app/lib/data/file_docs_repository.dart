import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'docs_repository.dart';
import 'orgs.dart';

typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

const _extensions = ['.md', '.json', '.diff'];
const _subdirs = ['details', 'reviews'];

class FileDocsRepository implements DocsRepository {
  FileDocsRepository(String workflowRoot, {ProcessRunner run = Process.run})
    : workflowRoot = normalizePath(workflowRoot),
      _run = run;

  final String workflowRoot;
  final ProcessRunner _run;

  @override
  Future<DocsListing> list(String project) async {
    final base = await _projectDir(project);
    if (base == null) return DocsListing.empty;
    final entries = <DocEntry>[];
    try {
      entries.addAll(await _files(base, ''));
      for (final sub in _subdirs) {
        entries.addAll(await _files(base, '$sub/'));
      }
    } on FileSystemException catch (e, st) {
      log('cannot list $project', name: 'FileDocsRepository', error: e, stackTrace: st);
      return DocsListing.empty;
    }
    return DocsListing.fromEntries(entries);
  }

  @override
  Future<DocText> read(String project, String rel) async {
    if (!_acceptedRel(rel)) return DocText.error('caminho recusado: $rel');
    final base = await _projectDir(project);
    if (base == null) return DocText.error('projeto inexistente: $project');
    try {
      final canonical = await _resolve('${base.raw}/$rel');
      if (canonical == null) return DocText.error('não encontrado: $rel');
      if (!_inside(base, canonical)) return DocText.error('fora do diretório do projeto: $rel');
      final stat = await FileStat.stat(canonical);
      if (stat.type != FileSystemEntityType.file) return DocText.error('não é arquivo: $rel');
      if (stat.size > kDocSizeLimit) return const DocText.tooLarge();
      return DocText.content(utf8.decode(await File(canonical).readAsBytes(), allowMalformed: true));
    } on FileSystemException catch (e, st) {
      log('cannot read $project/$rel', name: 'FileDocsRepository', error: e, stackTrace: st);
      return DocText.error('não foi possível ler $rel: ${e.osError?.message ?? e.message}');
    }
  }

  @override
  Future<void> open(Uri uri) async {
    if (!opensExternally(uri)) {
      log('link ignored: $uri', name: 'FileDocsRepository');
      return;
    }
    try {
      final result = await _run('open', [uri.toString()]);
      if (result.exitCode != 0) log('open failed for $uri: ${result.stderr}', name: 'FileDocsRepository');
    } on ProcessException catch (e, st) {
      log('cannot run open', name: 'FileDocsRepository', error: e, stackTrace: st);
    }
  }

  static bool _acceptedRel(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || !_extensions.any(rel.endsWith)) return false;
    return rel.split('/').every((s) => s.isNotEmpty && !s.startsWith('.'));
  }

  /// [raw] keeps the requested spelling for building child paths; [canonical] is what containment compares.
  Future<({String raw, String canonical})?> _projectDir(String project) async {
    if (project.isEmpty || project.contains('/') || project.startsWith('.')) return null;
    final raw = '$workflowRoot/$project';
    try {
      if (!await FileSystemEntity.isDirectory(raw)) return null;
      return (raw: raw, canonical: normalizePath(await Directory(raw).resolveSymbolicLinks()));
    } on FileSystemException {
      return null;
    }
  }

  /// Canonical path of [path] when it resolves inside the project dir, else `null`.
  Future<String?> _contained(({String raw, String canonical}) base, String path) async {
    final canonical = await _resolve(path);
    return canonical != null && _inside(base, canonical) ? canonical : null;
  }

  /// `null` when [path] does not exist.
  Future<String?> _resolve(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  static bool _inside(({String raw, String canonical}) base, String canonical) =>
      canonical.startsWith('${base.canonical}/');

  /// Direct, non-hidden files of `<project>/<prefix>` with an accepted extension; symlinks that leave the
  /// project are skipped so the listing never offers what [read] refuses.
  Future<List<DocEntry>> _files(({String raw, String canonical}) base, String prefix) async {
    final dir = Directory('${base.raw}/$prefix');
    if (!await dir.exists()) return const [];
    final out = <DocEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = entity.path.substring(entity.path.lastIndexOf('/') + 1);
      final rel = '$prefix$name';
      if (!_acceptedRel(rel)) continue;
      final canonical = await _contained(base, entity.path);
      if (canonical == null) continue;
      final stat = await FileStat.stat(canonical);
      if (stat.type != FileSystemEntityType.file) continue;
      out.add(DocEntry(rel: rel, size: stat.size, modified: stat.modified));
    }
    return out;
  }
}
