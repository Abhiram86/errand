import 'package:flutter/services.dart';

class IntentService {
  static const MethodChannel _channel = MethodChannel('intent');

  /// Launch an intent with a specific [action] ("open_url", "open_app", etc.).
  /// [androidAction] overrides the raw Android intent action (e.g.
  /// "android.intent.action.SET_ALARM"); when null the native side picks
  /// a sensible default per [action].
  Future<String> launchAction(
    String action, {
    String? androidAction,
    String? data,
    String? package,
    Map<String, String>? extras,
    String? type,
  }) async {
    final result = await _channel.invokeMethod<String>('launch', {
      'action': action,
      'androidAction': androidAction,
      'data': data,
      'package': package,
      'extras': extras,
      'type': type,
    });
    return result ?? 'ok';
  }

  /// Check if any activity can handle the given [action]/[data]/[package].
  Future<bool> canResolve({
    String? action,
    String? data,
    String? package,
  }) async {
    return await _channel.invokeMethod<bool>('canResolve', {
      'action': action ?? 'android.intent.action.VIEW',
      'data': data,
      'package': package,
    }) ??
        false;
  }

  /// Whether WRITE_SETTINGS is already granted. No UI is shown.
  Future<bool> hasWriteSettings() async {
    return await _channel.invokeMethod<bool>('hasWriteSettings') ?? false;
  }

  /// Request WRITE_SETTINGS permission (opens system dialog for sideloaded apps).
  /// Returns true if already granted, false if settings was opened.
  Future<bool> requestWriteSettings() async {
    final res = await _channel.invokeMethod<bool>('requestWriteSettings');
    return res ?? false;
  }

  /// Toggle a system setting (e.g., dark_mode).
  /// Returns a success message string.
  Future<String> toggleSystemSetting(String setting, int value) async {
    final result = await _channel.invokeMethod<String>('system_toggle', {
      'setting': setting,
      'value': value,
    });
    return result ?? 'Toggle applied';
  }
}