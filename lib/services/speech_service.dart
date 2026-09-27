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

  /// Sound level normalized to 0.0 – 1.0 during active speech recognition.
  final ValueNotifier<double> soundLevel = ValueNotifier(0.0);

  bool get isInitialized => _initialized;

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onStatus: (status) {
        final isList = status == 'listening';
        if (isList) {
          listening.value = true;
        } else if (status == 'notListening' || status == 'done') {
          listening.value = false;
          soundLevel.value = 0.0;
        }
      },
      onError: (_) {
        listening.value = false;
        soundLevel.value = 0.0;
      },
    );
    if (_initialized) {
      _speech.unexpectedPhraseAggregator = cleanSpeechPhrases;
    }
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
  }) async {
    soundLevel.value = 0.0;
    listening.value = true;
    try {
      await _speech.listen(
        onResult: (result) {
          final cleaned = cleanSpeechText(result.recognizedWords);
          onResult(cleaned, result.finalResult);
          if (result.finalResult) {
            listening.value = false;
            soundLevel.value = 0.0;
          }
        },
        onSoundLevelChange: (level) {
          // Android speech_to_text reports RMS dB (typically -2..10+).
          // Map to 0.0-1.0 with exponential smoothing to avoid UI jitter:
          // clamp floor at ~0.5dB so silence stays 0, scale 0.5..9, then
          // low-pass filter (70% old + 30% new).
          final clamped = level <= 0.5
              ? 0.0
              : level >= 9.0
                  ? 1.0
                  : (level - 0.5) / 8.5;
          final smoothed = soundLevel.value * 0.7 + clamped * 0.3;
          // Skip tiny updates to avoid rebuilding the composer at 20Hz.
          if ((smoothed - soundLevel.value).abs() < 0.02) return;
          soundLevel.value = smoothed.clamp(0.0, 1.0);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          localeId: localeId,
          pauseFor: pauseFor,
          listenFor: listenFor,
        ),
      );
    } catch (_) {
      listening.value = false;
      soundLevel.value = 0.0;
      rethrow;
    }
  }

  Future<void> stop() async {
    listening.value = false;
    soundLevel.value = 0.0;
    await _speech.stop();
  }

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

  /// Cleans and deduplicates spoken text when device speech engines
  /// (such as Android Google Speech Recognizer) deliver repeated sentences or phrases.
  static String cleanSpeechText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;

    String normalize(String s) {
      final noPunct = s.replaceAll(RegExp(r'[^\w\s]'), '').toLowerCase();
      return noPunct.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    final normFull = normalize(trimmed);
    if (normFull.isEmpty) return text;

    // 1. Character-level exact repeat without spaces (e.g. 'hellohello')
    if (trimmed.length >= 4 && trimmed.length % 2 == 0) {
      final halfLen = trimmed.length ~/ 2;
      if (trimmed.substring(0, halfLen).toLowerCase() ==
          trimmed.substring(halfLen).toLowerCase()) {
        return trimmed.substring(0, halfLen);
      }
    }

    // 2. Sentence-level split by punctuation: '.', '?', '!'
    final sentenceMatches = trimmed
        .split(RegExp(r'(?<=[.?!])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (sentenceMatches.length >= 2 && sentenceMatches.length % 2 == 0) {
      final mid = sentenceMatches.length ~/ 2;
      final s1 = sentenceMatches.sublist(0, mid).join(' ');
      final s2 = sentenceMatches.sublist(mid).join(' ');
      if (normalize(s1) == normalize(s2)) {
        return s1;
      }
    }

    // 3. Word-level split
    final words = trimmed.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      // 3a. Exact midpoint split
      if (words.length % 2 == 0) {
        final mid = words.length ~/ 2;
        final w1 = words.sublist(0, mid).join(' ');
        final w2 = words.sublist(mid).join(' ');
        if (normalize(w1) == normalize(w2)) {
          if (w1.endsWith('.') || w1.endsWith('?') || w1.endsWith('!')) {
            return w1;
          }
          if (w2.endsWith('.') || w2.endsWith('?') || w2.endsWith('!')) {
            return '$w1${w2.substring(w2.length - 1)}';
          }
          return w1;
        }
      }

      // 3b. Any split point k where normalized prefix equals normalized suffix
      for (var k = 1; k < words.length; k++) {
        final prefix = words.sublist(0, k).join(' ');
        final suffix = words.sublist(k).join(' ');
        if (normalize(prefix) == normalize(suffix)) {
          return prefix;
        }
      }

      // 3c. Prefix/suffix overlap (e.g. 'call mom. call mom now')
      for (var k = 1; k < words.length; k++) {
        final prefix = words.sublist(0, k).join(' ');
        final suffix = words.sublist(k).join(' ');
        final np = normalize(prefix);
        final ns = normalize(suffix);
        if (np.isNotEmpty && ns.isNotEmpty && (np.startsWith(ns) || ns.startsWith(np))) {
          if (np.length >= 8 && (np.length - ns.length).abs() <= 6) {
            return np.length >= ns.length ? prefix : suffix;
          }
        }
      }
    }

    return trimmed;
  }
}

/// Clean phrase aggregator that deduplicates identical or prefix/subsumed phrases
/// produced by certain device speech engines instead of concatenating duplicate text.
String cleanSpeechPhrases(List<String> phrases) {
  if (phrases.isEmpty) return '';
  final cleaned = <String>[];
  for (final phrase in phrases) {
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) continue;
    if (cleaned.isEmpty) {
      cleaned.add(trimmed);
      continue;
    }
    final last = cleaned.last;
    if (last.toLowerCase() == trimmed.toLowerCase()) {
      continue;
    }
    if (trimmed.toLowerCase().startsWith(last.toLowerCase())) {
      cleaned[cleaned.length - 1] = trimmed;
      continue;
    }
    if (last.toLowerCase().startsWith(trimmed.toLowerCase())) {
      continue;
    }
    cleaned.add(trimmed);
  }
  return cleaned.join(' ');
}
