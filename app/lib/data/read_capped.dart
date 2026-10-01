import 'dart:convert';
import 'dart:developer';
import 'dart:io';

/// Ausente (ou não é arquivo) é `text == null && problem == null`.
typedef CappedRead = ({String? text, String? problem});

Future<CappedRead> readCapped(String path, int limit) async {
  try {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return (text: null, problem: null);
    if (stat.size > limit) return (text: null, problem: 'grande demais');
    return (text: utf8.decode(await File(path).readAsBytes(), allowMalformed: true), problem: null);
  } on FileSystemException catch (e, st) {
    log('cannot read $path', name: 'readCapped', error: e, stackTrace: st);
    return (text: null, problem: 'ilegível');
  }
}
