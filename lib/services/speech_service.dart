import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'app_settings.dart';

/// Thin singleton over the device's built-in speech recognizer
/// (via the `speech_to_text` plugin). Zero shipped model weight —
/// recognition quality/network behavior follows the device's voice typing.
///
/// `initialize()` must happen once per app session and the plugin requires a
/// single instance, hence the singleton. Mic permission goes through the
/// existing "intent" MethodChannel (hasMicPermission / requestMicPermission),
/// matching how storage and WRITE_SETTINGS permissions are handled.
class SpeechService {
  SpeechService._();

  static final SpeechService instance = SpeechService._();

  static const _channel = MethodChannel('intent');

  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;

  /// Drives the composer mic button: true while a listen session is active.
  final ValueNotifier<bool> listening = ValueNotifier(false);

  bool get isInitialized => _initialized;

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onStatus: (status) => listening.value = status == 'listening',
      onError: (_) => listening.value = false,
    );
    return _initialized;
  }

  /// Locales installed on the device for speech recognition.
  Future<List<LocaleName>> locales() => _speech.locales();

  /// Starts listening. [onResult] fires with cumulative recognized text;
  /// [isFinal] is true on the session's last callback.
  ///
  /// [pauseFor]: silence longer than this ends the session (the platform's
  /// own timeout is shorter and varies by device — this makes the stop feel
  /// deliberate). [listenFor]: absolute cap on one utterance.
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    String? localeId,
    Duration pauseFor = const Duration(seconds: 5),
    Duration listenFor = const Duration(minutes: 2),
  }) {
    return _speech.listen(
      onResult: (result) => onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        localeId: localeId,
        pauseFor: pauseFor,
        listenFor: listenFor,
      ),
    );
  }

  Future<void> stop() => _speech.stop();

  // -- Persisted language choice (app-settings table; one string key) ------

  Future<String?> savedLocaleId() =>
      AppSettingsService.instance.loadVoiceLocaleId();

  Future<void> saveLocaleId(String? localeId) =>
      AppSettingsService.instance.saveVoiceLocaleId(localeId);

  // -- Mic permission via the platform channel -----------------------------

  Future<bool> hasMicPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasMicPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Resolves with the user's grant decision (the native side replies from
  /// onRequestPermissionsResult).
  Future<bool> requestMicPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestMicPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
