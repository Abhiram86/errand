import 'package:flutter/foundation.dart';

// Lightweight startup and notification profiling markers.
// Output is active in debug and profile builds, and silent in release builds.
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
