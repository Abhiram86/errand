import 'dart:async';

/// Serializes overlapping async writes, coalescing bursts into at most one
/// trailing run.
///
/// The first caller executes [write] immediately; callers arriving mid-write
/// only set a flag and wait. When the active write finishes, a single
/// trailing run executes the latest state if anyone arrived meanwhile, and
/// every waiter is released after that trailing run completes. Failures in
/// [write] propagate to the executing caller only; waiters resolve normally
/// and the writer stays usable.
class CoalescingWriter {
  Future<void>? _active;
  bool _needsTrailing = false;

  /// Completes when no write is in flight.
  Future<void> get settled => _active ?? Future.value();

  Future<void> run(Future<void> Function() write) async {
    if (_active != null) {
      _needsTrailing = true;
      await _active;
      return;
    }
    final completer = Completer<void>();
    _active = completer.future;
    try {
      do {
        _needsTrailing = false;
        await write();
      } while (_needsTrailing);
    } finally {
      _active = null;
      completer.complete();
    }
  }
}
