import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/flow_repository.dart';

/// Rebuilds with the global autopilot flag (`FlowRepository.watchAutoMode`); `null` until the first read.
class AutoModeBuilder extends StatefulWidget {
  const AutoModeBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, bool? on) builder;

  @override
  State<AutoModeBuilder> createState() => _AutoModeBuilderState();
}

class _AutoModeBuilderState extends State<AutoModeBuilder> {
  StreamSubscription<bool>? _sub;
  FlowRepository? _repository;
  bool? _on;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = RepositoryScope.of(context);
    if (identical(repository, _repository)) return;
    _repository = repository;
    unawaited(_sub?.cancel());
    _sub = repository.watchAutoMode().listen((on) => setState(() => _on = on));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _on);
}
