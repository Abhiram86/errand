import 'dart:async';

/// Serializes overlapping async writes, coalescing bursts into at most one
/// trailing run.
///
/// The first caller executes [write] immediately; callers arriving mid-write
/// only set a flag and wait. When the active write finishes, a single
/// trailing run executes the latest state if anyone arrived meanwhile, and
/// every waiter is released after that trailing run completes.
///
/// Failure handling: the exception from [write] propagates to the caller that
/// executed it. The pending-trailing flag is preserved so a queued write is
/// still attempted rather than silently dropped, and a failure during that
/// trailing run is rethrown to the caller that requested it. Previously a throw
/// exited the loop and every waiter resolved as if its own write had landed,
/// which hid a lost final persist behind a debugPrint at the call site.
class CoalescingWriter {
  Future<void>? _active;
  bool _needsTrailing = false;

  /// Error from the most recent trailing run, consumed by the next waiter.
  Object? _trailingError;
  StackTrace? _trailingStack;

  /// Completes when no write is in flight.
  Future<void> get settled => _active ?? Future.value();

  Future<void> run(Future<void> Function() write) async {
    if (_active != null) {
      _needsTrailing = true;
      await _active;
      // Surface a failure from the trailing run that ran on our behalf. Without
      // this, a caller whose write actually failed sees a clean completion.
      final err = _trailingError;
      if (err != null) {
        final st = _trailingStack;
        _trailingError = null;
        _trailingStack = null;
        Error.throwWithStackTrace(err, st ?? StackTrace.current);
      }
      return;
    }
    final completer = Completer<void>();
    _active = completer.future;
    try {
      var firstError = true;
      while (true) {
        _needsTrailing = false;
        try {
          await write();
        } catch (error, stackTrace) {
          if (firstError) rethrow;
          // A trailing run is best-effort recovery for an earlier failure that
          // is already propagating. Keep the writer usable and hand this failure
          // to the waiter that queued it.
          _trailingError = error;
          _trailingStack = stackTrace;
        }
        firstError = false;
        if (!_needsTrailing) break;
      }
    } finally {
      _active = null;
      completer.complete();
    }
  }
}
