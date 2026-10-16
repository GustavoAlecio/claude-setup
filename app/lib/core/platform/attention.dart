import 'dart:developer';

import 'package:flutter/services.dart';

const _channel = MethodChannel('claude_flow/attention');

/// macOS notifications and the Dock badge (`AppDelegate.swift`). Without the native side (tests) every call is a no-op.
class AttentionChannel {
  const AttentionChannel();

  Future<void> notify({required String id, required String title, required String body, required String route}) =>
      _call('notify', {'id': id, 'title': title, 'body': body, 'route': route});

  Future<void> badge(int count) => _call('badge', {'count': count});

  /// `true` when unknown: better to skip a banner than to show one over the app itself.
  Future<bool> isActive() async {
    try {
      return await _channel.invokeMethod<bool>('isActive') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException catch (e, st) {
      log('isActive failed', name: 'Attention', error: e, stackTrace: st);
      return true;
    }
  }

  /// A click on a notification hands back its route.
  void onOpen(void Function(String route) open) => _channel.setMethodCallHandler((call) async {
    if (call.method != 'open') return;
    if (call.arguments case {'route': final String route}) open(route);
  });

  Future<void> _call(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e, st) {
      log('$method failed', name: 'Attention', error: e, stackTrace: st);
    }
  }
}
