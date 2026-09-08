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

  /// Programmatically disables the accessibility service via disableSelf().
  /// Surfaced in Settings > Tools ("Disable now") so the user can pause
  /// screen access without leaving the app. Note disableSelf() is async at
  /// the OS level — callers must not trust an immediate isEnabled() re-read.
  Future<bool> disableService() async {
    try {
      return await _channel.invokeMethod<bool>('disable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reads the active window as a compact text outline. Identical consecutive
  /// reads return {ok, unchanged: true, message} unless [full] is set.
  /// With [probe], returns ONLY {ok, changed} without updating the stored
  /// snapshot — used as the post-action effect check.
  ///
  /// Returns {ok, package?, outline?, nodes?, truncated?, unchanged?,
  /// capHit?, elements?, changed?, error?, message?}.
  Future<Map<String, dynamic>> readScreen({
    int maxNodes = 300,
    bool full = false,
    bool probe = false,
  }) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('readScreen', {
      'maxNodes': maxNodes,
      'full': full,
      'probe': probe,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Effect check: did the screen change since the last full read?
  /// Returns {ok, changed: bool}. Never dumps content.
  /// Default 600ms keeps plain tap/scroll effect checks snappy; the
  /// then_read path uses its own 1000ms settle for toggles/animations.
  Future<Map<String, dynamic>> probeChanged({int settleMs = 600}) async {
    if (settleMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: settleMs));
    }
    final res = await readScreen(probe: true);
    return {'ok': res['ok'] == true, 'changed': res['changed'] == true};
  }

  /// Taps (or long-clicks) the element addressed by numeric [ref] from the
  /// last screen read. Returns {ok, message?}.
  Future<Map<String, dynamic>> tapByRef(int ref, {bool longClick = false}) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('tapRef', {
      'ref': ref,
      'longClick': longClick,
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

  /// Scrolls [direction] (up/down/left/right) [times] times in one call
  /// (wheels move one unit per scroll; lists one page). With [nearLabel],
  /// only the scrollable whose subtree contains that text is targeted.
  /// Returns {ok, method?, scrolled?, at_end?, ...}.
  Future<Map<String, dynamic>> scroll(
    String direction, {
    int times = 1,
    String? nearLabel,
  }) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('scroll', {
      'direction': direction,
      'times': times,
      'nearLabel': nearLabel,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Long-clicks the element addressed by numeric [ref] from the last read.
  Future<Map<String, dynamic>> longPressByRef(int ref) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('tapRef', {
      'ref': ref,
      'longClick': true,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Sends Escape through the focused field's input connection (dismisses
  /// some dialogs/popups). Returns {ok, message}.
  Future<Map<String, dynamic>> imeSendEscape() async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('imeSendEscape');
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Identity + content of the currently focused editable field (IME mode,
  /// API 33+). Returns {ok, fieldId?, hint?, content?, error?, message?}.
  Future<Map<String, dynamic>> imeFieldInfo() async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('imeFieldInfo');
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Commits [text] into the focused field via the IME input connection
  /// (works where SET_TEXT is refused, e.g. web inputs). Returns {ok,
  /// content?} with the post-write field contents.
  Future<Map<String, dynamic>> imeCommit(String text, {bool replaceAll = true}) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('imeCommit', {
      'text': text,
      'replaceAll': replaceAll,
    });
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
  }

  /// Sends a Tab key through the focused field's input connection (moves to
  /// next form field). Returns {ok, message}.
  Future<Map<String, dynamic>> imeSendTab() async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('imeSendTab');
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
