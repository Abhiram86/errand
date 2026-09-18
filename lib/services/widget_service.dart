import 'dart:async';
import 'package:flutter/services.dart';

/// Service managing interactions from native Android AppWidgets (e.g. Home Screen Voice Widget).
class WidgetService {
  static final WidgetService instance = WidgetService._internal();

  final MethodChannel _channel = const MethodChannel('widget');
  final _voicePromptController = StreamController<void>.broadcast();

  bool _initialized = false;

  WidgetService._internal();

  /// Stream of voice prompt trigger events sent while the app is running or resumed.
  Stream<void> get onVoicePrompt => _voicePromptController.stream;

  /// Initializes the method call handler to listen for events from the native widget.
  void initialize() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onVoicePrompt':
          _voicePromptController.add(null);
          break;
        default:
          break;
      }
    });
  }

  /// Checks if the app was cold-started via the home screen voice widget.
  /// Consumes the pending flag on the native side so it is only triggered once.
  Future<bool> consumeInitialVoicePrompt() async {
    try {
      final result = await _channel.invokeMethod<bool>('consumeInitialVoicePrompt');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _voicePromptController.close();
    _initialized = false;
  }
}
