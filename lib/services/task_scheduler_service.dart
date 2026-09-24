import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/agent_runner.dart';
import '../llm/llm_client.dart';
import '../models/llm_provider.dart';
import '../services/app_settings.dart';
import '../services/database.dart';
import '../services/notification_service.dart';
import '../services/workspace.dart';
import '../tools/file_tools.dart';
import '../utils/app_profile.dart';

/// Service responsible for coordinating background task scheduling with
/// native Android AlarmManager and WorkManager.
/// Result of [TaskSchedulerService.computeEditTransition]: the status,
// next run time, and stored interval a settings edit should persist.
class TaskEditTransition {
  final String status;
  final int? nextRunAt;
  final int? repeatAfter;

  const TaskEditTransition({
    required this.status,
    required this.nextRunAt,
    required this.repeatAfter,
  });
}

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

  static const MethodChannel _channel = MethodChannel('task_scheduler');

  final Map<int, CancelToken> _runningTokens = {};

  /// Checks if a task is currently executing in-process.
  bool isTaskRunning(int taskId) => _runningTokens.containsKey(taskId);

  /// Deletes a task and everything tied to it: stops an in-flight run first
   /// so it cannot complete-or-notify afterwards, then cancels the native
   /// alarm and posted notification before removing the row (logs cascade).
   /// Returns false when the task does not exist.
   Future<bool> deleteTask(int taskId) async {
     final existing = await (db.select(db.schedulerTasks)
           ..where((t) => t.id.equals(taskId)))
         .getSingleOrNull();
     if (existing == null) return false;
     await cancelRunningTask(taskId);
     await cancelTask(taskId);
     try {
       await notificationService.cancelNotification(taskId);
     } catch (_) {}
     await (db.delete(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
         .go();
     return true;
   }

  /// Returns the number of execution logs that still have an unseen
  /// completion notification.
  Future<int> unreadNotificationCount() async {
    final count = db.schedulerTaskLogs.id.count();
    final row = await (db.selectOnly(db.schedulerTaskLogs)
          ..addColumns([count])
          ..where(db.schedulerTaskLogs.notificationSeen.equals(0) &
              db.schedulerTaskLogs.notificationSent.equals(1) &
              db.schedulerTaskLogs.status.isIn(const [
                'success',
                'failed',
                'timeout',
                'cancelled',
              ])))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Marks unseen terminal logs for [taskId] as seen when its notification is tapped.
  /// Running rows are excluded: a tap that lands mid-run must not consume
  /// the completion's unread state.
  Future<void> markNotificationTapped(int taskId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (db.update(db.schedulerTaskLogs)
          ..where((l) =>
              l.schedulerTaskId.equals(taskId) &
              l.notificationSeen.equals(0) &
              l.status.isIn(const [
                'success',
                'failed',
                'timeout',
                'cancelled',
              ])))
        .write(
      SchedulerTaskLogsCompanion(
        notificationSeen: const Value(1),
        updatedAt: Value(now),
      ),
    );
  }

  /// Cancels an actively running task execution and marks it cancelled in the database.
  Future<void> cancelRunningTask(int taskId) async {
    final token = _runningTokens[taskId];
    token?.cancel();

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    await (db.update(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId) & t.status.equals('running')))
        .write(
      SchedulerTasksCompanion(
        status: const Value('cancelled'),
        nextRunAt: const Value(null),
        updatedAt: Value(nowMillis),
      ),
    );

    await (db.update(db.schedulerTaskLogs)
          ..where((l) =>
              l.schedulerTaskId.equals(taskId) & l.status.equals('running')))
        .write(
      SchedulerTaskLogsCompanion(
        status: const Value('cancelled'),
        finishedAt: Value(nowMillis),
        errorMessage: const Value('Cancelled by user'),
        updatedAt: Value(nowMillis),
      ),
    );
  }

  final StreamController<Map<String, dynamic>> _notificationClicks =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of notification clicks delivered while the app is active.
  Stream<Map<String, dynamic>> get notificationClicks => _notificationClicks.stream;

  Future<Map<String, dynamic>?>? _pendingNotificationFuture;

  /// Retrieves any cold-launch notification click intent that started the app.
  ///
  /// Reuses the in-flight lookup started early during [initialize] so cold
  /// notification routing does not wait to initiate the channel IPC after
  /// the first frame.
  Future<Map<String, dynamic>?> getPendingNotificationClick() {
    return _pendingNotificationFuture ??= _fetchPendingNotificationClick();
  }

  Future<Map<String, dynamic>?> _fetchPendingNotificationClick() async {
    AppProfile.mark('pending_channel_start');
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getPendingNotificationClick');
      AppProfile.mark('pending_channel_done found=${res != null}');
      return res;
    } catch (_) {
      AppProfile.mark('pending_channel_error');
      return null;
    }
  }

  /// Clears the cached pending notification future after consumption.
  void clearPendingNotificationClick() {
    _pendingNotificationFuture = null;
  }

  /// Attaches method call handler to receive `executeTask` and `rescheduleAll`
  /// triggers from native Android AlarmManager / WorkManager.
  void initialize() {
    // Start pending notification lookup non-blocking before runApp()
    _pendingNotificationFuture ??= _fetchPendingNotificationClick();

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'executeTask':
          final args = call.arguments;
          final taskId = (args is Map) ? (args['taskId'] as int? ?? -1) : -1;
          if (taskId > 0) {
            return await executeTask(taskId);
          }
          return false;
        case 'rescheduleAll':
          return await rescheduleAllActiveTasks();
        case 'onTaskNotificationClicked':
          final args = call.arguments;
          if (args is Map) {
            _notificationClicks.add(Map<String, dynamic>.from(args));
          }
          return true;
        default:
          return null;
      }
    });
  }

  /// Schedules the next trigger for [taskId] with native Android AlarmManager.
  ///
  /// Called when a task is created, updated, resumed, or rescheduled.
  Future<void> scheduleTask(int taskId) async {
    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (task == null ||
        task.status == 'paused' ||
        task.status == 'cancelled' ||
        task.status == 'completed') {
      return;
    }

    final targetTime = task.nextRunAt ?? task.startsAt;
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    // Schedule for at least 1s into the future
    final triggerAt = targetTime > nowMillis ? targetTime : nowMillis + 1000;

    try {
      final scheduled = await _channel.invokeMethod<bool>('scheduleAlarm', {
        'taskId': taskId,
        'triggerAtMillis': triggerAt,
        'title': task.title,
      });
      if (scheduled == false) {
        debugPrint(
          '[TaskSchedulerService] Exact alarm denied for task $taskId; '
          'falling back to inexact timing. Ask the user to grant exact alarms.',
        );
      }
    } catch (_) {}
  }

  /// Cancels any scheduled alarm for [taskId] with native Android AlarmManager.
  ///
  /// Called when a task is paused, cancelled, or deleted.
  Future<void> cancelTask(int taskId) async {
    try {
      await _channel.invokeMethod('cancelAlarm', {
        'taskId': taskId,
      });
    } catch (_) {}
  }

  /// Pauses all currently active ('scheduled') tasks and cancels their native alarms.
  ///
  /// Returns the number of tasks that were paused.
  Future<int> pauseAllTasks() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final activeTasks = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .get();

    if (activeTasks.isEmpty) return 0;

    await (db.update(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .write(
      SchedulerTasksCompanion(
        status: const Value('paused'),
        updatedAt: Value(nowMillis),
      ),
    );

    for (final task in activeTasks) {
      await cancelTask(task.id);
    }

    return activeTasks.length;
  }

  /// Resumes all 'paused' tasks, recalculates nextRunAt if elapsed, and schedules alarms.
  ///
  /// Returns the number of tasks that were resumed.
  Future<int> resumeAllTasks() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final pausedTasks = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('paused')))
        .get();

    if (pausedTasks.isEmpty) return 0;

    for (final task in pausedTasks) {
      int? nextRun = task.nextRunAt ?? task.startsAt;
      if (nextRun <= nowMillis) {
        if (task.type == 'recurring' &&
            task.repeatAfter != null &&
            task.repeatAfter! > 0) {
          nextRun = calculateNextRunAt(
            startsAt: task.startsAt,
            repeatAfter: task.repeatAfter!,
            nowMillis: nowMillis,
          );
        } else {
          nextRun = nowMillis + 60000;
        }
      }

      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(task.id)))
          .write(
        SchedulerTasksCompanion(
          status: const Value('scheduled'),
          nextRunAt: Value(nextRun),
          updatedAt: Value(nowMillis),
        ),
      );
      await scheduleTask(task.id);
    }

    return pausedTasks.length;
  }

  /// In-flight reschedule guard: concurrent triggers (app start plus
  /// MY_PACKAGE_REPLACED/boot) join the same run instead of double-scheduling.
  Future<int>? _rescheduleInFlight;

  /// Re-registers all active tasks in 'scheduled' status with the native AlarmManager.
  ///
  /// Called on device boot or app startup. Concurrent callers share one run.
  Future<int> rescheduleAllActiveTasks() {
    final existing = _rescheduleInFlight;
    if (existing != null) return existing;
    final future = _runRescheduleAllActiveTasks();
    _rescheduleInFlight = future;
    future.whenComplete(() {
      if (identical(_rescheduleInFlight, future)) _rescheduleInFlight = null;
    });
    return future;
  }

  Future<int> _runRescheduleAllActiveTasks() async {
    AppProfile.mark('reschedule_start');
    await recoverStuckTasks();

    final scheduled = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .get();

    for (final task in scheduled) {
      await scheduleTask(task.id);
    }
    AppProfile.mark('reschedule_done count=${scheduled.length}');
    return scheduled.length;
  }

  /// Checks whether exact alarms can be scheduled without permission denials.
  Future<bool> canScheduleExactAlarms() async {
    try {
      final result = await _channel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens system exact alarms settings page on Android 12+ (API 31+).
  Future<bool> openExactAlarmSettings() async {
    try {
      final result = await _channel.invokeMethod<bool>('openExactAlarmSettings');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Outcome of editing a task's schedule type/interval in settings sheets.
  /// Outcome of editing a task's schedule type/interval in settings sheets.
  /// Pure and unit-tested: the sheet must apply exactly this, so status and
  /// alarm transitions can't drift between UI and logic.
  /// - Switching to (or reconfiguring) recurring recomputes a future grid slot.
  /// - Terminal states (`failed`/`cancelled`/`completed`) auto-resurrect to
  ///   `scheduled` whenever the result is runnable; `paused`/`running` are
  ///   never touched.
  /// - One-off keeps a future `nextRunAt`, anchors a past one to now + 60s.
  static TaskEditTransition computeEditTransition({
    required String oldType,
    required String oldStatus,
    required int? oldNextRunAt,
    required int? oldRepeatAfter,
    required String newType,
    required int newRepeatAfter,
    required int startsAt,
    required int nowMillis,
  }) {
    final typeChanged = oldType != newType;
    int? nextRun = oldNextRunAt;
    String newStatus = oldStatus;
    int? outRepeatAfter;
    if (newType == 'recurring') {
      outRepeatAfter = newRepeatAfter;
      final intervalChanged = oldRepeatAfter != newRepeatAfter;
      if (typeChanged ||
          intervalChanged ||
          nextRun == null ||
          nextRun <= nowMillis) {
        nextRun = calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: newRepeatAfter,
          nowMillis: nowMillis,
        );
      }
      if (newStatus == 'failed' ||
          newStatus == 'cancelled' ||
          newStatus == 'completed') {
        newStatus = 'scheduled';
      }
    } else {
      outRepeatAfter = null;
      if (typeChanged) {
        if (nextRun != null && nextRun <= nowMillis) {
          nextRun = nowMillis + 60000;
        }
        if ((newStatus == 'failed' ||
                newStatus == 'cancelled' ||
                newStatus == 'completed') &&
            nextRun != null) {
          newStatus = 'scheduled';
        }
      }
    }
    return TaskEditTransition(
      status: newStatus,
      nextRunAt: nextRun,
      repeatAfter: outRepeatAfter,
    );
  }

  /// Calculates the next execution timestamp for a recurring task anchored at [startsAt]
  /// with interval [repeatAfter] in milliseconds (Strict Option A grid).
  ///
  /// Guarantees that the returned timestamp is strictly greater than [nowMillis]
  /// and aligns exactly to `startsAt + n * repeatAfter`, eliminating execution drift.
  static int calculateNextRunAt({
    required int startsAt,
    required int repeatAfter,
    required int nowMillis,
  }) {
    if (repeatAfter <= 0) return nowMillis + 60000;
    if (nowMillis < startsAt) return startsAt;
    final elapsed = nowMillis - startsAt;
    final n = (elapsed ~/ repeatAfter) + 1;
    return startsAt + (n * repeatAfter);
  }

  /// Sweeps tasks that were left in `running` status due to process crashes or kills.
  ///
  /// Tasks running longer than [maxRunningDuration] are considered abandoned.
  /// If [task.notify] is true and the task was interrupted recently (within [freshKillWindow]),
  /// dispatches a failure notification to alert the user of the killed run.
  Future<int> recoverStuckTasks({
    Duration maxRunningDuration = const Duration(minutes: 15),
    Duration freshKillWindow = const Duration(hours: 4),
  }) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final cutoff =
        nowMillis - maxRunningDuration.inMilliseconds;
    final freshCutoff = nowMillis - freshKillWindow.inMilliseconds;

    final stuckTasks = await (db.select(db.schedulerTasks)
          ..where((t) =>
              t.status.equals('running') &
              t.updatedAt.isSmallerThanValue(cutoff)))
        .get();

    for (final task in stuckTasks) {
      if (task.type == 'recurring' &&
          task.repeatAfter != null &&
          task.repeatAfter! > 0) {
        final nextRun = calculateNextRunAt(
          startsAt: task.startsAt,
          repeatAfter: task.repeatAfter!,
          nowMillis: nowMillis,
        );
        await (db.update(db.schedulerTasks)
              ..where((t) => t.id.equals(task.id)))
            .write(
          SchedulerTasksCompanion(
            status: const Value('scheduled'),
            nextRunAt: Value(nextRun),
            updatedAt: Value(nowMillis),
          ),
        );
        await scheduleTask(task.id);
      } else {
        await (db.update(db.schedulerTasks)
              ..where((t) => t.id.equals(task.id)))
            .write(
          SchedulerTasksCompanion(
            status: const Value('failed'),
            updatedAt: Value(nowMillis),
          ),
        );
      }

      await (db.update(db.schedulerTaskLogs)
            ..where((l) =>
                l.schedulerTaskId.equals(task.id) & l.status.equals('running')))
          .write(
        SchedulerTaskLogsCompanion(
          status: const Value('timeout'),
          finishedAt: Value(nowMillis),
          errorMessage:
              const Value('Task execution interrupted or killed by system.'),
          updatedAt: Value(nowMillis),
        ),
      );

      // Notify on fresh kill if notifications are enabled for the task.
      // Stale boot recoveries beyond the freshKillWindow are recovered silently.
      final isFreshKill = task.updatedAt >= freshCutoff ||
          (task.lastRunAt != null && task.lastRunAt! >= freshCutoff);
      if (task.notify && isFreshKill) {
        try {
          await notificationService.showNotification(
            id: task.id,
            title: 'Task Interrupted: ${task.title}',
            body: 'Task execution was killed or interrupted by the system.',
            isSuccess: false,
          );
        } catch (_) {}
      }
    }
    return stuckTasks.length;
  }

  /// Entry point invoked when AlarmManager or WorkManager fires for [taskId].
  ///
  /// Runs an isolated, headless agent turn, saves the markdown report to `.scratch/`,
  /// updates database state and execution logs, and dispatches a system notification if enabled.
  Future<bool> executeTask(
    int taskId, {
    bool allowCompleted = false,
    AgentRunner? runner,
    Directory? scratchDirectory,
    Duration timeout = const Duration(minutes: 10),
    CancelToken? cancelToken,
  }) async {
    // 1. Allowlist guard: only scheduled tasks (or failed tasks for retry) can be executed.
    // Rejects already running tasks, paused, and cancelled tasks.
    // Completed tasks are rejected unless allowCompleted is true (e.g. manual UI trigger).
    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    final allowedStatuses = allowCompleted
        ? const ['scheduled', 'failed', 'completed']
        : const ['scheduled', 'failed'];
    if (task == null || !allowedStatuses.contains(task.status)) {
      return false;
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    // 2. Atomic claim: transition from allowed statuses to 'running'.
    // Prevents double-execution if AlarmManager and WorkManager fire concurrently.
    final claimedRows = await (db.update(db.schedulerTasks)
          ..where((t) =>
              t.id.equals(taskId) &
              t.status.isIn(allowedStatuses)))
        .write(
      SchedulerTasksCompanion(
        status: const Value('running'),
        lastRunAt: Value(nowMillis),
        totalRuns: Value(task.totalRuns + 1),
        updatedAt: Value(nowMillis),
      ),
    );
    if (claimedRows == 0) {
      return false;
    }

    final scheduledFor = task.nextRunAt ?? task.startsAt;
    // The task can be deleted between the claim above and this insert, which
    // would violate the log FK. Distinguish that (quiet exit, nothing to
    // show) from a transient DB failure (mark failed so it stays visible).
    int logId;
    try {
      logId = await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: scheduledFor,
          startedAt: Value(nowMillis),
          status: 'running',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
    } catch (_) {
      final stillThere = await (db.select(db.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .getSingleOrNull();
      if (stillThere == null) return false;
      final finishMillis = DateTime.now().millisecondsSinceEpoch;
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        SchedulerTasksCompanion(
          status: const Value('failed'),
          failures: Value(task.failures + 1),
          updatedAt: Value(finishMillis),
        ),
      );
      if (task.notify) {
        try {
          await notificationService.showNotification(
            id: taskId,
            title: 'Task Failed: ${task.title}',
            body: 'Could not start execution (database error).',
            isSuccess: false,
          );
        } catch (_) {}
      }
      return false;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(task.payloadJson) as Map<String, dynamic>;
    } catch (_) {
      payload = {};
    }
    final prompt = (payload['prompt'] as String?)?.trim() ?? task.title;

    AgentRunner? agentRunner = runner;
    LlmClient? locallyCreatedClient;
    if (agentRunner == null) {
      try {
        final settings = AppSettingsService.instance;
        final targetProviderId = payload['providerId'] as String?;
        final targetModel = (payload['model'] as String?)?.trim();

        // Resolve provider (override or active default)
        LlmProvider provider = settings.activeProvider;
        if (targetProviderId != null && targetProviderId.isNotEmpty) {
          final found = settings.providers.where((p) => p.id == targetProviderId).firstOrNull;
          if (found != null) {
            provider = found;
          }
        }

        final model = (targetModel != null && targetModel.isNotEmpty)
            ? targetModel
            : settings.selectedModel;

        final apiKey = provider.id == ProviderPresetType.openRouter.id
            ? (provider.apiKey ?? settings.openRouterKey ?? '')
            : (provider.apiKey ?? '');
        locallyCreatedClient = LlmClient(
          config: LlmConfig(
            baseUrl: provider.baseUrl.isNotEmpty
                ? provider.baseUrl
                : provider.defaultBaseUrl,
            apiKey: apiKey,
            model: model,
          ),
          // Autonomous runs get a larger retry budget: no human is around
          // to tap retry when a transient failure exhausts the budget.
          maxAttempts: 5,
        );
        agentRunner = AgentRunner(
          llm: locallyCreatedClient,
          workingDirectory: WorkingDirectory(Workspace.instance.documentsDir),
          selectedModel: model,
        );
      } catch (_) {}
    }

    if (agentRunner == null) {
      final finishMillis = DateTime.now().millisecondsSinceEpoch;
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          finishedAt: Value(finishMillis),
          status: const Value('failed'),
          errorMessage: const Value('No LLM client configured for background task execution.'),
          updatedAt: Value(finishMillis),
        ),
      );
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        SchedulerTasksCompanion(
          status: const Value('failed'),
          failures: Value(task.failures + 1),
          updatedAt: Value(finishMillis),
        ),
      );
      if (task.notify) {
        try {
          await notificationService.showNotification(
            id: taskId,
            title: 'Task Failed: ${task.title}',
            body: 'No LLM client configured for background task execution.',
          );
        } catch (_) {}
      }
      return false;
    }

    final effectiveCancelToken = cancelToken ?? CancelToken();
    _runningTokens[taskId] = effectiveCancelToken;
    HeadlessRunResult result;
    var isTimeout = false;

    try {
      result = await agentRunner
          .runHeadless(
            taskId: taskId,
            prompt: prompt,
            taskTitle: task.title,
            scratchDirectory: scratchDirectory,
            db: db,
            schedulerService: this,
            cancelToken: effectiveCancelToken,
          )
          .timeout(timeout);
    } on TimeoutException {
      isTimeout = true;
      effectiveCancelToken.cancel();
      result = HeadlessRunResult(
        ok: false,
        output: '',
        errorMessage: 'Task timed out after ${timeout.inSeconds} seconds.',
      );
    } catch (e) {
      result = HeadlessRunResult(
        ok: false,
        output: '',
        errorMessage: e.toString(),
      );
    } finally {
      _runningTokens.remove(taskId);
      locallyCreatedClient?.close();
    }

    final finishMillis = DateTime.now().millisecondsSinceEpoch;

    // Re-read: the task may have been deleted or cancelled from another
    // isolate while running (a UI cancel cannot reach this isolate's token).
    // Deleted → stay silent (no row to update, no notification for a task
    // the user removed). Cancelled → honor it instead of overwriting.
    final freshTask = await (db.select(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (freshTask == null) return false;

    if ((effectiveCancelToken.isCancelled && !isTimeout) ||
        freshTask.status == 'cancelled') {
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        SchedulerTasksCompanion(
          status: const Value('cancelled'),
          nextRunAt: const Value(null),
          updatedAt: Value(finishMillis),
        ),
      );
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          status: const Value('cancelled'),
          finishedAt: Value(finishMillis),
          errorMessage: const Value('Cancelled by user'),
          updatedAt: Value(finishMillis),
        ),
      );
      return false;
    }

    final isSuccess = result.ok;

    // The runner guarantees reportPath (save_report tool or final-answer
    // fallback). Verify the file actually exists; prune older reports for
    // this task so recurring runs don't fill scratch unboundedly.
    String? reportPath = result.reportPath;
    final scratch = scratchDirectory ?? Workspace.instance.scratchDir;
    try {
      if (reportPath != null && !File(reportPath).existsSync()) {
        reportPath = null;
      }
      _pruneOldReports(scratch, taskId, keep: 10, keepPath: reportPath);
    } catch (_) {}

    // Extract one-line summary for logs and notification
    final summary = result.output.trim().split('\n').firstWhere(
      (line) => line.trim().isNotEmpty,
      orElse: () => isSuccess
          ? 'Task completed successfully.'
          : (result.errorMessage ?? 'Task failed.'),
    );

    final logStatus = isTimeout ? 'timeout' : (isSuccess ? 'success' : 'failed');

    await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
      SchedulerTaskLogsCompanion(
        finishedAt: Value(finishMillis),
        status: Value(logStatus),
        outputFilePath: Value(reportPath),
        summary: Value(summary),
        errorMessage: Value(result.errorMessage),
        updatedAt: Value(finishMillis),
      ),
    );

    if (isSuccess) {
      if (task.type == 'recurring' && task.repeatAfter != null && task.repeatAfter! > 0) {
        final nextRun = calculateNextRunAt(
          startsAt: task.startsAt,
          repeatAfter: task.repeatAfter!,
          nowMillis: finishMillis,
        );
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
          SchedulerTasksCompanion(
            status: const Value('scheduled'),
            nextRunAt: Value(nextRun),
            failures: const Value(0),
            updatedAt: Value(finishMillis),
          ),
        );
        await scheduleTask(taskId);
      } else {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
          SchedulerTasksCompanion(
            status: const Value('completed'),
            nextRunAt: const Value(null),
            failures: const Value(0),
            updatedAt: Value(finishMillis),
          ),
        );
      }
    } else {
      final newFailures = task.failures + 1;
      final maxRetries = task.retriesPerTurn;
      final hasExceededRetries = maxRetries > 0 && newFailures >= maxRetries;

      if (task.type == 'recurring' && task.repeatAfter != null && task.repeatAfter! > 0) {
        if (hasExceededRetries) {
          // Exceeded max consecutive retries; mark as failed until user intervenes
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
            SchedulerTasksCompanion(
              status: const Value('failed'),
              nextRunAt: const Value(null),
              failures: Value(newFailures),
              updatedAt: Value(finishMillis),
            ),
          );
        } else {
          // Reschedule for next regular interval so transient network glitches do not kill recurring tasks
          final nextRun = calculateNextRunAt(
            startsAt: task.startsAt,
            repeatAfter: task.repeatAfter!,
            nowMillis: finishMillis,
          );
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
            SchedulerTasksCompanion(
              status: const Value('scheduled'),
              nextRunAt: Value(nextRun),
              failures: Value(newFailures),
              updatedAt: Value(finishMillis),
            ),
          );
          await scheduleTask(taskId);
        }
      } else {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
          SchedulerTasksCompanion(
            status: const Value('failed'),
            nextRunAt: const Value(null),
            failures: Value(newFailures),
            updatedAt: Value(finishMillis),
          ),
        );
      }
    }

    if (task.notify) {
      bool shown = false;
      String skipReason = '';
      try {
        final notifTitle = isSuccess
            ? 'Task Completed: ${task.title}'
            : 'Task Failed: ${task.title}';
        final notifBody = summary.length > 250
            ? '${summary.substring(0, 247)}...'
            : summary;
        shown = await notificationService.showNotification(
          id: taskId,
          title: notifTitle,
          body: notifBody,
          isSuccess: isSuccess,
        );
        if (!shown) {
          skipReason = 'suppressed (permission denied or channel missing)';
        }
      } catch (e) {
        skipReason = 'threw: $e';
      }
      // Record honestly whether the shade actually got the notification --
      // marking unsent rows as sent makes missing notifications undebuggable.
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          notificationSent: Value(shown ? 1 : 0),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      if (!shown) {
        debugPrint(
          '[TaskScheduler] Notification not shown for task $taskId: $skipReason',
        );
      }
    } else {
      debugPrint(
        '[TaskScheduler] Notifications disabled for task $taskId; skipping.',
      );
      // Silent runs have notify: false and no notification is posted.
      // Mark notificationSeen: 1 so they do not pollute the unread tab or badge count.
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          notificationSent: const Value(0),
          notificationSeen: const Value(1),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
    }

    locallyCreatedClient?.close();

    return isSuccess;
  }

  /// Deletes older `task-<taskId>-*` reports in [scratch], keeping the newest
  /// [keep] files so recurring tasks don't fill the disk unboundedly.
  /// Never deletes the file at [keepPath] (the current run's report).
  void _pruneOldReports(Directory scratch, int taskId,
      {int keep = 10, String? keepPath}) {
    try {
      if (!scratch.existsSync()) return;
      final prefix = 'task-$taskId-';
      final reports = scratch
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith(prefix))
          .toList();
      reports.sort((a, b) {
        DateTime aTime, bTime;
        try {
          aTime = a.lastModifiedSync();
        } catch (_) {
          aTime = DateTime.fromMillisecondsSinceEpoch(0);
        }
        try {
          bTime = b.lastModifiedSync();
        } catch (_) {
          bTime = DateTime.fromMillisecondsSinceEpoch(0);
        }
        return bTime.compareTo(aTime);
      });
      for (final f in reports.skip(keep)) {
        if (keepPath != null && f.path == keepPath) continue;
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
