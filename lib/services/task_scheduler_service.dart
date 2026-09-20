import '../services/database.dart';
import '../services/notification_service.dart';

/// Service responsible for coordinating background task scheduling with
/// native Android AlarmManager and WorkManager.
class TaskSchedulerService {
  static final TaskSchedulerService instance = TaskSchedulerService();

  final ErrandDatabase db;
  final NotificationService notificationService;

  TaskSchedulerService({
    ErrandDatabase? database,
    NotificationService? notificationService,
  })  : db = database ?? ErrandDatabase.instance,
        notificationService =
            notificationService ?? NotificationService.instance;

  /// Schedules the next trigger for [taskId].
  ///
  /// Called when a task is created, updated, or resumed.
  Future<void> scheduleTask(int taskId) async {
    // TODO: Register task trigger with Android AlarmManager (for exact one-off/wall-clock runs)
    // or WorkManager (for periodic background work with device constraints).
  }

  /// Cancels any scheduled alarm or background work for [taskId].
  ///
  /// Called when a task is paused, cancelled, or deleted.
  Future<void> cancelTask(int taskId) async {
    // TODO: Cancel active alarm or worker for taskId with Android AlarmManager / WorkManager.
  }

  /// Entry point invoked when AlarmManager or WorkManager fires for [taskId].
  Future<bool> executeTask(int taskId) async {
    // TODO: Implement headless agent execution turn and report saving when alarm/worker fires.
    return true;
  }
}
