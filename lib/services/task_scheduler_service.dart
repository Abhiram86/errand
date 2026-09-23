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

  /// Returns the number of execution logs that still have an unseen
  /// completion notification.
  Future<int> unreadNotificationCount() async {
    final count = db.schedulerTaskLogs.id.count();
    final row = await (db.selectOnly(db.schedulerTaskLogs)
          ..addColumns([count])
          ..where(db.schedulerTaskLogs.notificationSeen.equals(0)))
        .getSingle();
    return row.read(count) ?? 0;
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

  /// Retrieves any cold-launch notification click intent that started the app.
  Future<Map<String, dynamic>?> getPendingNotificationClick() async {
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

  /// Attaches method call handler to receive `executeTask` and `rescheduleAll`
  /// triggers from native Android AlarmManager / WorkManager.
  void initialize() {
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

  /// Sweeps tasks that were left in `running` status due to process crashes or kills.
  ///
  /// Tasks running longer than [maxRunningDuration] are considered abandoned.
  Future<int> recoverStuckTasks({
    Duration maxRunningDuration = const Duration(minutes: 15),
  }) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - maxRunningDuration.inMilliseconds;
    final stuckTasks = await (db.select(db.schedulerTasks)
          ..where((t) =>
              t.status.equals('running') &
              t.updatedAt.isSmallerThanValue(cutoff)))
        .get();

    for (final task in stuckTasks) {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      if (task.type == 'recurring' &&
          task.repeatAfter != null &&
          task.repeatAfter! > 0) {
        await (db.update(db.schedulerTasks)
              ..where((t) => t.id.equals(task.id)))
            .write(
          SchedulerTasksCompanion(
            status: const Value('scheduled'),
            nextRunAt: Value(nowMillis + task.repeatAfter!),
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
    }
    return stuckTasks.length;
  }

  /// Entry point invoked when AlarmManager or WorkManager fires for [taskId].
  ///
  /// Runs an isolated, headless agent turn, saves the markdown report to `.scratch/`,
  /// updates database state and execution logs, and dispatches a system notification if enabled.
  Future<bool> executeTask(
    int taskId, {
    AgentRunner? runner,
    Directory? scratchDirectory,
    Duration timeout = const Duration(minutes: 10),
    CancelToken? cancelToken,
  }) async {
    // 1. Allowlist guard: only scheduled tasks (or failed tasks for retry) can be executed.
    // Rejects already running tasks, paused, cancelled, and completed tasks.
    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (task == null || (task.status != 'scheduled' && task.status != 'failed')) {
      return false;
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    // 2. Atomic claim: transition from 'scheduled' or 'failed' to 'running'.
    // Prevents double-execution if AlarmManager and WorkManager fire concurrently.
    final claimedRows = await (db.update(db.schedulerTasks)
          ..where((t) =>
              t.id.equals(taskId) & t.status.isIn(const ['scheduled', 'failed'])))
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
    final logId = await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: scheduledFor,
        startedAt: Value(nowMillis),
        status: 'running',
        createdAt: nowMillis,
        updatedAt: nowMillis,
      ),
    );

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

    if (effectiveCancelToken.isCancelled && !isTimeout) {
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
        final nextRun = finishMillis + task.repeatAfter!;
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
          final nextRun = finishMillis + task.repeatAfter!;
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
      try {
        final notifTitle = isSuccess
            ? 'Task Completed: ${task.title}'
            : 'Task Failed: ${task.title}';
        final notifBody = summary.length > 250
            ? '${summary.substring(0, 247)}...'
            : summary;
        await notificationService.showNotification(
          id: taskId,
          title: notifTitle,
          body: notifBody,
          isSuccess: isSuccess,
        );
        await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
          SchedulerTaskLogsCompanion(
            notificationSent: const Value(1),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      } catch (_) {}
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
