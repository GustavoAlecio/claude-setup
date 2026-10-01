import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class StreamCubit<T> extends Cubit<AsyncSnapshot<T>> {
  StreamCubit(Stream<T> source) : super(AsyncSnapshot<T>.waiting()) {
    _subscription = source.listen(
      (value) => emit(AsyncSnapshot<T>.withData(ConnectionState.active, value)),
      onError: (Object error, StackTrace stackTrace) {
        log('stream error', name: 'StreamCubit<$T>', error: error, stackTrace: stackTrace);
        emit(AsyncSnapshot<T>.withError(ConnectionState.active, error, stackTrace));
      },
      onDone: () => emit(state.inState(ConnectionState.done)),
    );
  }

  late final StreamSubscription<T> _subscription;

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
