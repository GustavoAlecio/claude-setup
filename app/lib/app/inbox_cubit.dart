import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/github_models.dart';
import '../data/github_repository.dart';

class InboxState {
  const InboxState({this.inbox, this.error});

  /// Last successful answer; kept while a reload runs or fails.
  final Inbox? inbox;
  final String? error;

  /// Tab badge: nothing while in error.
  int get badge => error == null ? inbox?.items.length ?? 0 : 0;
}

/// Single source of the inbox tab and its badge; polls only while the engine has an endpoint.
class InboxCubit extends Cubit<InboxState> {
  InboxCubit(this._github, Stream<Uri?> endpoint, {this.interval = const Duration(seconds: 120)})
    : super(const InboxState()) {
    _sub = endpoint.distinct().listen(_onEndpoint);
  }

  final GitHubRepository _github;
  final Duration interval;
  late final StreamSubscription<Uri?> _sub;
  Timer? _timer;
  bool _inFlight = false;
  bool _hasEndpoint = false;

  void _onEndpoint(Uri? base) {
    _hasEndpoint = base != null;
    _timer?.cancel();
    _timer = null;
    if (base == null) return;
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (_inFlight || !_hasEndpoint) return;
    _inFlight = true;
    try {
      final inbox = await _github.inbox();
      if (!isClosed) emit(InboxState(inbox: inbox));
    } on GitHubException catch (e) {
      if (!isClosed) emit(InboxState(inbox: state.inbox, error: e.message));
    } finally {
      _inFlight = false;
    }
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    await _sub.cancel();
    return super.close();
  }
}
