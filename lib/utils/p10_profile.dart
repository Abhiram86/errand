import 'package:flutter/foundation.dart';

// DEBUG_LOG(P10): one-shot launch-profiling markers for P10 step 1
// (notification-tap -> engine start -> first frame -> route push ->
// first route frame -> first useful task row).
// All output is active in debug AND profile builds (profiling needs it),
// silent in release builds, so shipping this file is safe.
// Grep for DEBUG_LOG to find and remove every marker when profiling is done.
//
// Readout: `flutter run` console or
// `adb logcat | grep -E "P10"` (Dart prints surface as `I/flutter [...] [P10] ...`;
// native prints surface as `I P10 : ...`).
final class P10Profile {
  static final Stopwatch _watch = Stopwatch();

  /// Starts the clock. Call as the very first line of `main()`.
  static void start() {
    if (!_watch.isRunning) _watch.start();
  }

  /// Logs `[P10] +<ms> <event>`. No-op in release builds.
  static void mark(String event) {
    if (!kDebugMode && !kProfileMode) return;
    debugPrint('[P10] +${_watch.elapsedMilliseconds}ms $event');
  }
}
