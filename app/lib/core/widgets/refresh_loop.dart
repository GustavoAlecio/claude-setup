import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';

/// Serializa [sync]: pedidos que chegam durante uma execução viram uma única rodada extra. Falha de
/// [sync] é logada e marca [refreshFailed] até a próxima rodada concluir, para a tela não mostrar
/// conteúdo velho em silêncio.
mixin RefreshLoop<T extends StatefulWidget> on State<T> {
  bool _busy = false;
  bool _again = false;
  bool refreshFailed = false;

  String get logName;

  Future<void> sync();

  void refresh() => unawaited(_run());

  Future<void> _run() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        try {
          await sync();
          if (refreshFailed && mounted) setState(() => refreshFailed = false);
        } catch (e, st) {
          log('refresh failed', name: logName, error: e, stackTrace: st);
          if (mounted) setState(() => refreshFailed = true);
        }
      } while (_again && mounted);
    } finally {
      _busy = false;
    }
  }
}
