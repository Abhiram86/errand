import 'dart:async';

enum TaskToastType { create, edit, delete }

class TaskToastEvent {
  final String message;
  final TaskToastType type;
  final int? taskId;

  const TaskToastEvent({
    required this.message,
    required this.type,
    this.taskId,
  });
}

/// Global event service for broadcasting task lifecycle toast notifications
/// (creation, update, deletion) across the application without parameter drilling.
class TaskToastService {
  TaskToastService._();
  static final TaskToastService instance = TaskToastService._();

  final StreamController<TaskToastEvent> _controller =
      StreamController<TaskToastEvent>.broadcast();

  Stream<TaskToastEvent> get stream => _controller.stream;

  void taskCreated(int taskId, String title) {
    _controller.add(
      TaskToastEvent(
        message: 'Task #$taskId scheduled: "$title"',
        type: TaskToastType.create,
        taskId: taskId,
      ),
    );
  }

  void taskUpdated(int taskId, String title) {
    _controller.add(
      TaskToastEvent(
        message: 'Task #$taskId updated: "$title"',
        type: TaskToastType.edit,
        taskId: taskId,
      ),
    );
  }

  void taskDeleted(int taskId, [String? title]) {
    final msg = title != null && title.isNotEmpty
        ? 'Task #$taskId deleted: "$title"'
        : 'Task #$taskId deleted';
    _controller.add(
      TaskToastEvent(
        message: msg,
        type: TaskToastType.delete,
        taskId: taskId,
      ),
    );
  }
}
