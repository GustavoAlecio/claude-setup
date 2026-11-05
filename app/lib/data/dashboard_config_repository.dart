import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'config_mutations.dart';

const kInvalidDashboardConfig = 'dashboard.json inválido; corrija antes de salvar';

/// The only writer of `.dashboard.json`. Each write re-reads the file, so keys changed on disk by the
/// engine or by hand survive; writes are serialized so two concurrent mutations never lose one another.
class FileDashboardConfigRepository {
  FileDashboardConfigRepository(this.path);

  final String path;

  static const _encoder = JsonEncoder.withIndent('  ');

  Future<void> _chain = Future<void>.value();

  Future<void> update(ConfigMutation mutation) {
    final next = _chain.then((_) => _write(mutation));
    _chain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(ConfigMutation mutation) async {
    final file = File(path);
    final out = applyConfigMutation(await _read(file), mutation);
    if (out == null) return;
    final tmp = File('$path.tmp');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString('${_encoder.convert(out)}\n', flush: true);
      await tmp.rename(path);
    } on FileSystemException catch (e, st) {
      log('cannot write $path', name: 'FileDashboardConfigRepository', error: e, stackTrace: st);
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException catch (_) {
        // Best effort: the rename never happened, so .dashboard.json itself is untouched.
      }
      throw ConfigWriteException('não foi possível gravar $path: ${e.message}');
    }
  }

  Future<Map<String, dynamic>> _read(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (e, st) {
      log('invalid $path; write refused', name: 'FileDashboardConfigRepository', error: e, stackTrace: st);
      throw const ConfigWriteException(kInvalidDashboardConfig);
    } on FileSystemException catch (e, st) {
      log('cannot read $path', name: 'FileDashboardConfigRepository', error: e, stackTrace: st);
      throw ConfigWriteException('não foi possível ler $path: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) throw const ConfigWriteException(kInvalidDashboardConfig);
    return decoded;
  }
}
