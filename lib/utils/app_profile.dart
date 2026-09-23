import 'package:flutter/foundation.dart';

// DEBUG_LOG: lightweight launch-profiling markers (first used for P10 step 1:
// notification-tap -> engine start -> first frame -> route push ->
// first route frame -> first useful task row).
// Active in debug AND profile builds (profiling needs it),
// silent in release builds, so shipping this file is safe.
// Grep for DEBUG_LOG to find every marker; pass a per-area `tag`
// (e.g. 'P10') to keep future profiling series distinguishable.
//
// Readout: `flutter run` console or e.g.
// `adb logcat | grep -E "P10"` (Dart prints surface as `I/flutter [...] [P10] ...`;
// native prints surface as `I P10 : ...`).
final class AppProfile {
  static final Stopwatch _watch = Stopwatch();

  /// Starts the clock. Call as the very first line of `main()`.
  static void start() {
    if (!_watch.isRunning) _watch.start();
  }

  /// Logs `[<tag>] +<ms> <event>`. No-op in release builds.
  static void mark(String event, {String tag = 'P10'}) {
    if (!kDebugMode && !kProfileMode) return;
    debugPrint('[$tag] +${_watch.elapsedMilliseconds}ms $event');
  }
}
