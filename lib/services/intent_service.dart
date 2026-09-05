import 'package:flutter/services.dart';

class IntentService {
  static const MethodChannel _channel = MethodChannel('intent');

  /// Launch an intent with a specific [action] ("open_url", "open_app", etc.).
  /// [androidAction] overrides the raw Android intent action (e.g.
  /// "android.settings.DISPLAY_SETTINGS"); when null the native side picks
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

  /// Brings Errand to the foreground (reordering task stack without recreating activity).
  /// Used after the agent finishes automated work in another app so the user sees the summary.
  Future<void> bringToFront() async {
    try {
      await _channel.invokeMethod<void>('bringToFront');
    } catch (_) {}
  }

  // -- Foreground work indicator -------------------------------------------
  //
  // Held while an agent turn runs. Keeps the process out of Android's
  // cached state (whose freezer kills TCP sockets ~10s after backgrounding)
  // so SSE streams survive when the intent tool opens another app.

  /// Starts the foreground-service notification. Best-effort: failures are
  /// swallowed because a missing indicator must never fail the turn.
  Future<void> startWorkIndicator() async {
    try {
      await _channel.invokeMethod<void>('startWorkIndicator');
    } catch (_) {}
  }

  Future<void> stopWorkIndicator() async {
    try {
      await _channel.invokeMethod<void>('stopWorkIndicator');
    } catch (_) {}
  }

  /// One-time POST_NOTIFICATIONS grant so the indicator is visible on
  /// API 33+. Safe to call repeatedly.
  Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } catch (_) {}
  }
}