import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' show min;

import '../engine/engine_config.dart';
import 'session_models.dart';
import 'session_reducer.dart';
import 'sessions_repository.dart';
import 'sse.dart';

class HttpSessionsRepository implements SessionsRepository {
  /// [endpoint] emits the engine base URL, or `null` while the engine is stopped (no reconnects then).
  HttpSessionsRepository(Stream<Uri?> endpoint, {Duration Function(int attempt) backoff = defaultBackoff})
    : _backoff = backoff {
    _endpointSub = endpoint.listen(_onEndpoint);
  }

  static Duration defaultBackoff(int attempt) => Duration(milliseconds: min(500 * (1 << min(attempt, 5)), 10000));

  final Duration Function(int attempt) _backoff;
  final _client = HttpClient();
  late final StreamSubscription<Uri?> _endpointSub;
  Uri? _base;

  List<SessionSummary>? _list;
  final _listUpdates = StreamController<List<SessionSummary>>.broadcast();
  final _listConn = _Connection();
  int _listListeners = 0;

  final _details = <String, _Detail>{};

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.multi((controller) {
    final current = _list;
    if (current != null) controller.add(current);
    final sub = _listUpdates.stream.listen(controller.add, onError: controller.addError);
    if (_listListeners++ == 0) _startList();
    controller.onCancel = () {
      unawaited(sub.cancel());
      if (--_listListeners == 0) _listConn.stop();
    };
  });

  @override
  Stream<SessionDetail> watchSession(String id) => Stream.multi((controller) {
    final detail = _details.putIfAbsent(id, () => _Detail(id));
    final current = detail.state;
    if (current != null) controller.add(current);
    final sub = detail.updates.stream.listen(controller.add, onError: controller.addError, onDone: controller.close);
    if (detail.listeners++ == 0) _startDetail(detail);
    controller.onCancel = () {
      unawaited(sub.cancel());
      if (--detail.listeners > 0) return;
      detail.conn.stop();
      if (_details[id] == detail) _details.remove(id);
    };
  });

  @override
  Future<List<PaletteSkill>> skills() async {
    final json = await _request('GET', '/api/skills');
    return [
      for (final s in (json is List ? json : const []).whereType<Map<String, dynamic>>())
        PaletteSkill(s['name'] as String? ?? '', s['description'] as String? ?? ''),
    ];
  }

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
  }) => _create({
    'project': project,
    'command': command,
    'cwd': ?cwd,
    'githubAccount': ?githubAccount,
    'permissionMode': permissionMode.wire,
  });

  @override
  Future<SessionSummary> createInOrg(
    String org,
    String command, {
    required String cwd,
    List<String> additionalDirectories = const [],
    String? githubAccount,
    required PermissionMode permissionMode,
  }) => _create({
    'org': org,
    'command': command,
    'cwd': cwd,
    'additionalDirectories': additionalDirectories,
    'githubAccount': ?githubAccount,
    'permissionMode': permissionMode.wire,
  });

  Future<SessionSummary> _create(Map<String, Object?> body) async {
    final json = await _request('POST', '/api/sessions', body: body);
    final summary = parseSummary(json as Map<String, dynamic>);
    _setList(upsertSummary(_list ?? const [], summary));
    return summary;
  }

  /// Not [_sessionPost]: an engine older than the route also answers 404, and that must not drop the session.
  @override
  Future<void> setPermissionMode(String id, PermissionMode mode) async {
    final json = await _request(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/permission-mode',
      body: {'mode': mode.wire},
    );
    if (json is Map<String, dynamic>) _setList(upsertSummary(_list ?? const [], parseSummary(json)));
  }

  @override
  Future<void> send(String id, String text) async {
    await _sessionPost(id, 'input', {'text': text});
    _reattach(id);
  }

  @override
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers}) =>
      _sessionPost(id, 'permission', {'requestId': requestId, 'decision': decision.name, 'answers': ?answers});

  @override
  Future<void> resume(String id) async {
    await _sessionPost(id, 'resume');
    _reattach(id);
  }

  @override
  Future<void> interrupt(String id) => _sessionPost(id, 'interrupt');

  Future<void> dispose() async {
    await _endpointSub.cancel();
    _listConn.stop();
    for (final d in _details.values) {
      d.conn.stop();
    }
    _client.close(force: true);
  }

  void _onEndpoint(Uri? base) {
    if (base == _base) return;
    _base = base;
    _listConn.stop();
    for (final d in _details.values) {
      d.conn.stop();
    }
    if (base == null) return;
    if (_listListeners > 0) _startList();
    for (final d in _details.values) {
      if (d.listeners > 0) _startDetail(d);
    }
  }

  void _setList(List<SessionSummary> list) {
    _list = list;
    _listUpdates.add(list);
  }

  void _removeFromList(String id) {
    final list = _list;
    if (list != null) _setList(list.where((s) => s.id != id).toList());
  }

  void _startList() => unawaited(
    _run(
      _listConn,
      (base) => base.replace(path: '/api/sessions/stream'),
      onFrame: (frame) => _setList(applySessionsFrame(_list ?? const [], frame)),
    ),
  );

  void _startDetail(_Detail detail) => unawaited(
    _run(
      detail.conn,
      (base) => base.replace(
        path: '/api/sessions/${Uri.encodeComponent(detail.id)}/stream',
        queryParameters: {'from': '${detail.state?.lastSeq ?? 0}'},
      ),
      before: () async {
        if (detail.state != null) return true;
        final known = _list?.where((s) => s.id == detail.id).firstOrNull;
        final summary = known ?? await _fetchSummary(detail.id);
        if (summary == null) return false;
        detail.emit(SessionDetail(summary: summary));
        return true;
      },
      onOpen: () => detail.emit(withoutPartial(detail.state!)),
      onFrame: (frame) => detail.emit(applyFrame(detail.state!, frame)),
      onNotFound: () {
        _removeFromList(detail.id);
        detail.updates.close();
      },
    ),
  );

  /// `closed` ends the stream without reconnecting; an input or resume brings a new process, so listen again.
  void _reattach(String id) {
    final detail = _details[id];
    if (detail == null || detail.listeners == 0 || detail.conn.running || _base == null) return;
    _startDetail(detail);
  }

  Future<SessionSummary?> _fetchSummary(String id) async {
    try {
      final json = await _request('GET', '/api/sessions/${Uri.encodeComponent(id)}');
      return parseSummary(json as Map<String, dynamic>);
    } on SessionsException catch (e) {
      if (e.statusCode == HttpStatus.notFound) return null;
      rethrow;
    }
  }

  Future<void> _sessionPost(String id, String action, [Map<String, Object?> body = const {}]) async {
    try {
      await _request('POST', '/api/sessions/${Uri.encodeComponent(id)}/$action', body: body);
    } on SessionsException catch (e) {
      if (e.statusCode == HttpStatus.notFound) _removeFromList(id);
      rethrow;
    }
  }

  Future<Object?> _request(String method, String path, {Map<String, Object?>? body}) async {
    final base = _base;
    if (base == null) throw const SessionsException('engine parado');
    final request = await _client.openUrl(method, base.replace(path: path));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      final json = _errorBody(text);
      final error = json is Map && json['error'] is String ? json['error'] as String : 'HTTP ${response.statusCode}';
      throw SessionsException(error, statusCode: response.statusCode);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// An unknown route (engine older than the app) answers with an HTML page instead of the engine's JSON error.
  static Object? _errorBody(String text) {
    try {
      return text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// One SSE connection with reconnect; returns when stopped, on `closed`, on 404 or when the engine stops.
  Future<void> _run(
    _Connection conn,
    Uri Function(Uri base) url, {
    required void Function(SseFrame frame) onFrame,
    Future<bool> Function()? before,
    void Function()? onOpen,
    void Function()? onNotFound,
  }) async {
    final generation = conn.start();
    bool alive() => conn.generation == generation && _base != null;
    var attempt = 0;
    try {
      while (alive()) {
        try {
          if (before != null && !await before()) {
            onNotFound?.call();
            return;
          }
          if (!alive()) return;
          final request = await _client.getUrl(url(_base!));
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          final response = await request.close();
          if (!alive()) {
            await response.listen(null).cancel();
            return;
          }
          if (response.statusCode == HttpStatus.notFound && onNotFound != null) {
            await response.listen(null).cancel();
            onNotFound();
            return;
          }
          if (response.statusCode != HttpStatus.ok) {
            await response.listen(null).cancel();
            throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
          }
          attempt = 0;
          onOpen?.call();
          if (await _consume(conn, generation, response, onFrame)) return;
        } on Exception catch (e, st) {
          if (alive()) log('sse ${url(_base!)}', name: 'HttpSessionsRepository', error: e, stackTrace: st);
        }
        if (!alive()) return;
        await Future<void>.delayed(_backoff(attempt++));
      }
    } finally {
      conn.finish(generation);
    }
  }

  /// Completes with `true` when the engine sent `closed` or the connection was stopped on purpose.
  Future<bool> _consume(
    _Connection conn,
    int generation,
    HttpClientResponse response,
    void Function(SseFrame) onFrame,
  ) {
    final done = Completer<bool>();
    var rest = '';
    late final StreamSubscription<String> sub;
    void finish(bool stop) {
      if (!done.isCompleted) done.complete(stop);
    }

    sub = response
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            final (frames, remainder) = parseSse(rest + chunk);
            rest = remainder;
            for (final frame in frames) {
              if (conn.generation != generation) return;
              onFrame(frame);
              if (frame.event == 'closed') {
                unawaited(sub.cancel());
                finish(true);
                return;
              }
            }
          },
          onError: (Object e, StackTrace st) {
            log('sse dropped', name: 'HttpSessionsRepository', error: e, stackTrace: st);
            finish(false);
          },
          onDone: () => finish(false),
          cancelOnError: true,
        );
    conn.cancel = () {
      unawaited(sub.cancel());
      finish(true);
    };
    return done.future;
  }
}

class _Connection {
  int generation = 0;
  bool running = false;
  void Function()? cancel;

  int start() {
    stop();
    running = true;
    return ++generation;
  }

  void stop() {
    generation++;
    running = false;
    cancel?.call();
    cancel = null;
  }

  void finish(int ended) {
    if (generation != ended) return;
    running = false;
    cancel = null;
  }
}

class _Detail {
  _Detail(this.id);

  final String id;
  final updates = StreamController<SessionDetail>.broadcast();
  final conn = _Connection();
  SessionDetail? state;
  int listeners = 0;

  void emit(SessionDetail next) {
    state = next;
    if (!updates.isClosed) updates.add(next);
  }
}
