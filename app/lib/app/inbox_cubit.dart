import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/github_models.dart';
import '../data/github_repository.dart';
import '../data/orgs.dart';

class InboxState {
  const InboxState({this.scope, this.inbox, this.error});

  /// Account and owners [inbox] was listed with; `null` until the config is read.
  final GithubScope? scope;

  /// Last successful answer for [scope]; kept while a reload runs or fails.
  final Inbox? inbox;
  final String? error;

  /// Tab badge: nothing while in error.
  int get badge => error == null ? inbox?.items.length ?? 0 : 0;
}

/// Single source of the inbox tab and its badge; polls only while the engine has an endpoint and the
/// current org's [GithubScope] is known.
class InboxCubit extends Cubit<InboxState> {
  InboxCubit(
    this._github,
    Stream<Uri?> endpoint,
    Stream<GithubScope> scope, {
    this.interval = const Duration(seconds: 120),
  }) : super(const InboxState()) {
    _endpointSub = endpoint.distinct().listen(_onEndpoint);
    _scopeSub = scope.distinct().listen(_onScope);
  }

  final GitHubRepository _github;
  final Duration interval;
  late final StreamSubscription<Uri?> _endpointSub;
  late final StreamSubscription<GithubScope> _scopeSub;
  Timer? _timer;
  bool _hasEndpoint = false;

  /// Bumped on every scope change: an answer of an older generation is for another org and is dropped.
  int _generation = 0;
  int? _inFlight;

  void _onEndpoint(Uri? base) {
    _hasEndpoint = base != null;
    _restart();
  }

  void _onScope(GithubScope scope) {
    _generation++;
    emit(InboxState(scope: scope));
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (!_hasEndpoint || state.scope == null) return;
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    final scope = state.scope;
    if (scope == null || !_hasEndpoint || _inFlight == _generation) return;
    final generation = _inFlight = _generation;
    try {
      final inbox = await _github.inbox(account: scope.account, owners: scope.owners);
      if (!isClosed && generation == _generation) emit(InboxState(scope: scope, inbox: inbox));
    } on GitHubException catch (e) {
      if (!isClosed && generation == _generation) {
        emit(InboxState(scope: scope, inbox: state.inbox, error: e.message));
      }
    } finally {
      if (_inFlight == generation) _inFlight = null;
    }
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    await _endpointSub.cancel();
    await _scopeSub.cancel();
    return super.close();
  }
}
