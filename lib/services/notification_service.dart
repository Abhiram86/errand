import 'package:flutter/services.dart';

/// Platform notification service for dispatching native Android notifications.
class NotificationService {
  static const MethodChannel _channel = MethodChannel('app_info');

  /// Production singleton instance.
  static final NotificationService instance = NotificationService();

  final MethodChannel _methodChannel;

  NotificationService({MethodChannel? channel})
      : _methodChannel = channel ?? _channel;

  /// Shows an Android system notification with [title] and [body].
  Future<bool> showNotification({
    required int id,
    required String title,
    required String body,
    String channelId = 'scheduled_tasks',
    String channelName = 'Scheduled Tasks',
  }) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>('showNotification', {
        'id': id,
        'title': title,
        'body': body,
        'channelId': channelId,
        'channelName': channelName,
      });
      return res ?? false;
    } catch (_) {
      try {
        final fallbackRes = await const MethodChannel('task_scheduler')
            .invokeMethod<bool>('showNotification', {
          'id': id,
          'title': title,
          'body': body,
          'channelId': channelId,
          'channelName': channelName,
        });
        return fallbackRes ?? false;
      } catch (_) {
        return false;
      }
    }
  }

  /// Cancels an active Android notification by [id].
  Future<bool> cancelNotification(int id) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>('cancelNotification', {
        'id': id,
      });
      return res ?? false;
    } catch (_) {
      try {
        final fallbackRes = await const MethodChannel('task_scheduler')
            .invokeMethod<bool>('cancelNotification', {
          'id': id,
        });
        return fallbackRes ?? false;
      } catch (_) {
        return false;
      }
    }
  }

  /// Checks if POST_NOTIFICATIONS permission is granted (true by default on < Android 13).
  Future<bool> hasPermission() async {
    try {
      final res =
          await _methodChannel.invokeMethod<bool>('hasNotificationPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Prompts the user to grant notification permission on Android 13+.
  Future<void> requestPermission() async {
    try {
      await _methodChannel.invokeMethod('requestNotificationPermission');
    } catch (_) {}
  }
}
