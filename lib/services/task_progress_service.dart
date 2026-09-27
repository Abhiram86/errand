import 'dart:async';
import 'package:flutter/foundation.dart';

enum TaskExecutionStage {
  starting,
  thinking,
  toolExecuting,
  toolCompleted,
  compacting,
  completed,
  failed,
}

class TaskProgressEvent {
  final int taskId;
  final TaskExecutionStage stage;
  final int turn;
  final String message;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final String? toolResultSnippet;
  final bool? toolOk;
  final bool isError;
  final DateTime timestamp;

  TaskProgressEvent({
    required this.taskId,
    required this.stage,
    this.turn = 0,
    required this.message,
    this.toolName,
    this.toolArgs,
    this.toolResultSnippet,
    this.toolOk,
    this.isError = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get stageLabel {
    switch (stage) {
      case TaskExecutionStage.starting:
        return 'Starting';
      case TaskExecutionStage.thinking:
        return 'Thinking';
      case TaskExecutionStage.toolExecuting:
        return 'Calling Tool';
      case TaskExecutionStage.toolCompleted:
        return toolOk == false ? 'Tool Failed' : 'Tool Finished';
      case TaskExecutionStage.compacting:
        return 'Compacting';
      case TaskExecutionStage.completed:
        return 'Completed';
      case TaskExecutionStage.failed:
        return 'Failed';
    }
  }
}

/// Service for monitoring and broadcasting live execution progress of headless tasks.
///
/// Gated entirely on [kDebugMode] — in release builds, emission is a no-op and
/// zero memory or logging overhead is incurred.
class TaskProgressService {
  TaskProgressService._();
  static final TaskProgressService instance = TaskProgressService._();

  final StreamController<TaskProgressEvent> _controller =
      StreamController<TaskProgressEvent>.broadcast();

  Stream<TaskProgressEvent> get stream => _controller.stream;

  final Map<int, TaskProgressEvent> _latestEvents = {};
  final Map<int, List<TaskProgressEvent>> _history = {};

  TaskProgressEvent? getLatest(int taskId) => _latestEvents[taskId];
  List<TaskProgressEvent> getHistory(int taskId) =>
      List<TaskProgressEvent>.unmodifiable(_history[taskId] ?? const []);

  void emit(TaskProgressEvent event) {
    if (!kDebugMode) return;

    _latestEvents[event.taskId] = event;
    final list = _history.putIfAbsent(event.taskId, () => []);
    list.add(event);
    if (list.length > 50) {
      list.removeAt(0);
    }

    _printDebugLog(event);

    _controller.add(event);
  }

  void clear(int taskId) {
    _latestEvents.remove(taskId);
    _history.remove(taskId);
  }

  void _printDebugLog(TaskProgressEvent event) {
    final prefix = '[Task #${event.taskId} | Debug]';
    switch (event.stage) {
      case TaskExecutionStage.starting:
        debugPrint('$prefix 🚀 ${event.message}');
      case TaskExecutionStage.thinking:
        debugPrint('$prefix 💭 Turn ${event.turn}: Thinking...');
      case TaskExecutionStage.toolExecuting:
        debugPrint('$prefix 🛠️ Turn ${event.turn}: Tool Call -> ${event.toolName}');
        if (event.toolArgs != null && event.toolArgs!.isNotEmpty) {
          debugPrint('   Args: ${event.toolArgs}');
        }
      case TaskExecutionStage.toolCompleted:
        final status = event.toolOk == false ? 'FAILED' : 'OK';
        debugPrint('$prefix ↳ Turn ${event.turn}: Tool Result -> ${event.toolName} ($status)');
        if (event.toolResultSnippet != null && event.toolResultSnippet!.isNotEmpty) {
          final snippet = event.toolResultSnippet!.length > 300
              ? '${event.toolResultSnippet!.substring(0, 300)}...'
              : event.toolResultSnippet!;
          debugPrint('   Output: $snippet');
        }
      case TaskExecutionStage.compacting:
        debugPrint('$prefix 📦 ${event.message}');
      case TaskExecutionStage.completed:
        debugPrint('$prefix ✅ ${event.message}');
      case TaskExecutionStage.failed:
        debugPrint('$prefix ❌ ${event.message}');
    }
  }
}
