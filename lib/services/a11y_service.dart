import 'package:flutter/services.dart';

/// Dart-side handle for the P2a accessibility channel ("a11y").
///
/// All methods are honest-failure: a disabled/restricted service surfaces as
/// [PlatformException] with codes NOT_ENABLED / RESTRICTED_SETTING, which the
/// screen tool maps into guidance the model can relay to the user.
class A11yService {
  static const MethodChannel _channel = MethodChannel('a11y');

  /// True only while the user has enabled the accessibility service.
  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when Android 13+ blocks *enabling* the service because this build
  /// was sideloaded via the non-session installer ("Restricted setting").
  Future<bool> isRestricted() async {
    try {
      return await _channel.invokeMethod<bool>('isRestricted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Settings > Accessibility (downloaded apps section) so the user can
  /// enable the service manually. Programmatic enablement is impossible by
  /// design.
  Future<void> openSettings() async {
    await _channel.invokeMethod<void>('openSettings');
  }

  /// Reads the active window as a compact text outline.
  ///
  /// Returns {ok, package?, outline?, nodes?, truncated?, error?, message?}.
  Future<Map<String, dynamic>> readScreen({int maxNodes = 300}) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('readScreen', {
      'maxNodes': maxNodes,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Performs a global navigation action: back | home | recents |
  /// notifications | quick_settings | lock_screen.
  /// Returns null on success, an error message string otherwise.
  Future<String?> globalAction(String name) async {
    return await _channel.invokeMethod<String>('globalAction', {'name': name});
  }

  // -- P2b: gated injection (Draft-mode primitives) --------------------------

  /// Taps the clickable element whose label matches [label] (case-insensitive;
  /// exact match preferred over prefix/contains unless [exact]). When several
  /// best-scoring matches exist, [occurrence] (1-based, outline order) picks
  /// one. Returns {ok, label?, error?, message?}.
  Future<Map<String, dynamic>> tapByText(
    String label, {
    bool exact = false,
    int occurrence = 1,
  }) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('tapByText', {
      'label': label,
      'exact': exact,
      'occurrence': occurrence,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Types [text] into the focused editable field (REPLACES content; password
  /// fields refused natively). Returns {ok, chars?, error?, message?}.
  Future<Map<String, dynamic>> typeText(String text) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('typeText', {
      'text': text,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Scrolls [down] toward later/earlier content, [times] times in one call
  /// (wheels move one unit per scroll; lists one page). With [nearLabel],
  /// only the scrollable whose subtree contains that text is targeted.
  /// Returns {ok, method?, scrolled?, at_end?, ...}.
  Future<Map<String, dynamic>> scroll({
    bool down = true,
    int times = 1,
    String? nearLabel,
  }) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('scroll', {
      'down': down,
      'times': times,
      'nearLabel': nearLabel,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Convenience: combined availability check used by tool handlers and the
  /// system-prompt builder. Returns (enabled, restricted).
  Future<(bool, bool)> availability() async {
    final enabled = await isEnabled();
    if (enabled) return (true, false);
    return (false, await isRestricted());
  }
}
