import 'dart:developer';

import 'package:flutter/services.dart';

const _channel = MethodChannel('claude_flow/clipboard');

/// PNG of the image on the macOS pasteboard (`AppDelegate.swift`), or `null` when it holds none. Flutter's
/// `Clipboard` only reads text.
Future<Uint8List?> readClipboardImage() async {
  try {
    return await _channel.invokeMethod<Uint8List>('image');
  } on PlatformException catch (e, st) {
    log('clipboard image unavailable', name: 'ClipboardImage', error: e, stackTrace: st);
    return null;
  } on MissingPluginException {
    return null;
  }
}
