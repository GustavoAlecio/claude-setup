import 'dart:convert';
import 'dart:developer';

import 'docs_repository.dart';

/// Os mesmos arquivos para qualquer projeto. [write] troca o conteúdo e o stamp; [reads] conta leituras
/// por `rel` e [opened] guarda os links aceitos, para os testes de releitura e de links.
class MockDocsRepository implements DocsRepository {
  MockDocsRepository([Map<String, String> files = syntheticDocs]) {
    files.forEach(write);
  }

  MockDocsRepository.empty();

  static final _epoch = DateTime.utc(2026, 3, 10, 12);

  final _files = <String, String>{};
  final _stamps = <String, DocEntry>{};
  final reads = <String, int>{};
  final opened = <Uri>[];
  int _version = 0;

  void write(String rel, String content) {
    _files[rel] = content;
    _stamps[rel] = DocEntry(
      rel: rel,
      size: utf8.encode(content).length,
      modified: _epoch.add(Duration(seconds: _version++)),
    );
  }

  void remove(String rel) {
    _files.remove(rel);
    _stamps.remove(rel);
  }

  @override
  Future<DocsListing> list(String project) async => DocsListing.fromEntries(_stamps.values);

  @override
  Future<DocText> read(String project, String rel) async {
    reads[rel] = (reads[rel] ?? 0) + 1;
    final content = _files[rel];
    if (content == null) return DocText.error('não encontrado: $rel');
    if (_stamps[rel]!.size > kDocSizeLimit) return const DocText.tooLarge();
    return DocText.content(content);
  }

  @override
  Future<void> open(Uri uri) async {
    if (!opensExternally(uri)) {
      log('link ignored: $uri', name: 'MockDocsRepository');
      return;
    }
    opened.add(uri);
  }
}

const syntheticDocs = {
  'spec.md':
      '---\nstatus: draft\n---\n# Spec: Exemplo\n\n## Regras\n\n- item com **negrito**\n  - aninhado\n\n'
      '| campo | tipo | nota |\n|---|---|---|\n| a | int | `x` |\n\nVer [plano](plan.md) e https://example.com.\n',
  'plan.md': '# Plano\n\n1. primeiro\n2. segundo\n\n```dart\nvoid main() {}\n```\n\n> citação\n',
  'tasks.md': '# Tasks\n\n- [x] T1\n- [ ] T2\n',
  'details/2026-03-10-cache.md': '# Detalhamento: cache\n\nTexto do detalhamento.\n',
  'details/2026-03-12-login.md': '# Detalhamento: login\n\n```mermaid\ngraph TD; A-->B\n```\n',
  'reviews/PR-157.md': '# Review PR-157\n\nDois achados no `lib/a.dart`.\n',
  'reviews/PR-157.diff':
      'diff --git a/lib/a.dart b/lib/a.dart\nindex 1111111..2222222 100644\n--- a/lib/a.dart\n+++ b/lib/a.dart\n'
      '@@ -1,3 +1,4 @@\n import \'b.dart\';\n-int a = 1;\n+int a = 2;\n+int c = 3;\n void f() {}\n'
      'diff --git a/lib/new.dart b/lib/new.dart\nnew file mode 100644\nindex 0000000..3333333\n--- /dev/null\n'
      '+++ b/lib/new.dart\n@@ -0,0 +1,2 @@\n+class New {}\n+// fim\n',
  'reviews/PR-157.comments.json':
      '[{"path": "lib/a.dart", "line": 3, "severity": "major", "agent": "dart-correctness", "body": "Use `final`."},'
      '{"path": "./lib/a.dart", "severity": "nit", "agent": "flutter-architecture", "body": "Nome genérico."},'
      '{"path": "lib/gone.dart", "line": 4, "severity": "critical", "agent": "security", "body": "Fora do diff."}]',
  'reviews/PR-157.meta.json':
      '{"number": 157, "title": "feat: cache de partidas", "body": "", "author": {"login": "dev-a"},'
      ' "baseRefName": "main", "headRefName": "feat/cache", "files": ['
      '{"path": "lib/a.dart", "additions": 2, "deletions": 1, "changeType": "MODIFIED"},'
      '{"path": "lib/new.dart", "additions": 2, "deletions": 0, "changeType": "ADDED"}]}',
  'reviews/PR-9.md': '# Review PR-9\n\nSem diff salvo.\n',
  'reviews/PR-9.meta.json':
      '{"number": 9, "title": "fix: login", "body": "", "author": {"login": "dev-b"},'
      ' "baseRefName": "main", "headRefName": "fix/login", "files": []}',
};
