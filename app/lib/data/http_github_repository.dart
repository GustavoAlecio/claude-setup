import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'github_models.dart';
import 'github_parser.dart';
import 'github_repository.dart';

class HttpGitHubRepository implements GitHubRepository {
  /// [endpoint] emits the engine base URL, or `null` while the engine is stopped.
  HttpGitHubRepository(Stream<Uri?> endpoint, {this.timeout = const Duration(seconds: 30)}) {
    _sub = endpoint.listen((base) => _base = base);
  }

  /// Whole request, body included; past it the call fails instead of holding the caller's in-flight flag.
  final Duration timeout;
  final _client = HttpClient();
  late final StreamSubscription<Uri?> _sub;
  Uri? _base;

  @override
  Future<List<PullRequest>> prs(String project) async =>
      parsePullRequests(await _get('/api/projects/${Uri.encodeComponent(project)}/prs'));

  @override
  Future<Inbox> inbox() async => parseInbox(await _get('/api/review-inbox'));

  Future<void> dispose() async {
    await _sub.cancel();
    _client.close(force: true);
  }

  Future<Object?> _get(String path) async {
    final base = _base;
    if (base == null) throw const GitHubException('engine iniciando');
    final int status;
    final Object? json;
    try {
      (status, json) = await _fetch(base.replace(path: path)).timeout(timeout);
    } on TimeoutException {
      throw const GitHubException('engine não respondeu');
    } on IOException catch (e) {
      throw GitHubException('engine inacessível: $e');
    } on Exception {
      throw const GitHubException('resposta inválida do engine');
    }
    if (status >= 400) {
      if (json is Map && json['error'] is String) throw GitHubException(json['error'] as String);
      if (status == HttpStatus.notFound) throw const GitHubException('engine desatualizado; reinicie');
      throw GitHubException('HTTP $status');
    }
    if (json == null) throw const GitHubException('resposta inválida do engine');
    return json;
  }

  /// A body that is not JSON is `null`: error statuses still carry their code.
  Future<(int, Object?)> _fetch(Uri uri) async {
    final response = await (await _client.getUrl(uri)).close();
    final text = await response.transform(utf8.decoder).join();
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    return (response.statusCode, json);
  }
}
