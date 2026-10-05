import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:errand/agent/task_checkpoint.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/notification_service.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/services/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockNotificationService extends NotificationService {
  final List<Map<String, dynamic>> shown = [];

  @override
  Future<bool> showNotification({
    required int id,
    required String title,
    required String body,
    String channelId = 'scheduled_tasks',
    String channelName = 'Scheduled Tasks',
    bool? isSuccess,
  }) async {
    shown.add({
      'id': id,
      'title': title,
      'body': body,
      'isSuccess': isSuccess,
    });
    return true;
  }
}

class _ExitReasonScheduler extends TaskSchedulerService {
  final List<Map<String, dynamic>> mockExitReasons;
  final List<int> scheduled = [];

  _ExitReasonScheduler({
    required super.database,
    required super.notificationService,
    this.mockExitReasons = const [],
  });

  @override
  Future<List<Map<String, dynamic>>> getHistoricalExitReasons({int maxNum = 5}) async {
    return mockExitReasons;
  }

  @override
  Future<void> scheduleTask(int taskId) async {
    scheduled.add(taskId);
  }
}

void main() {
  late ErrandDatabase db;
  late _MockNotificationService mockNotifs;
  late Directory tempDir;

  setUp(() async {
    db = ErrandDatabase.inMemory();
    mockNotifs = _MockNotificationService();
    tempDir = await Directory.systemTemp.createTemp('stale_heartbeat_test_');
    final scratch = Workspace.instance.scratchDir;
    if (scratch.existsSync()) {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    }
    await scratch.create(recursive: true);
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('recoverStuckTasks detects stale heartbeats (> 150s) even before 15m max duration', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Task started only 4 minutes ago (< 15m), but last heartbeat was 3 minutes ago (> 150s)
    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Stale Heartbeat Task',
        type: 'one_off',
        status: 'running',
        payloadJson: '{}',
        startsAt: now - 240000, // 4m ago
        timezone: 'UTC',
        createdAt: now - 240000,
        updatedAt: now - 240000, // 4m ago (NOT past 15m cutoff)
      ),
    );

    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 240000,
        status: 'running',
        lastHeartbeatAt: Value(now - 180000), // 3m ago (> 150s stale threshold)
        currentStep: const Value('turn 2 · tool bash'),
        createdAt: now - 240000,
        updatedAt: now - 180000,
      ),
    );

    final scheduler = _ExitReasonScheduler(
      database: db,
      notificationService: mockNotifs,
      mockExitReasons: [
        {
          'reason': 3,
          'reasonName': 'LOW_MEMORY',
          'description': 'Process killed by Android Low Memory Killer (LMK)',
          'timestamp': now - 179000,
        }
      ],
    );

    final recoveredCount = await scheduler.recoverStuckTasks(
      maxRunningDuration: const Duration(minutes: 15),
      staleHeartbeatDuration: const Duration(seconds: 150),
    );

    expect(recoveredCount, equals(1));

    // Verify task row transitioned to failed
    final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    expect(taskRow.status, equals('failed'));

    // Verify log row recorded the matched LOW_MEMORY exit reason
    final logRow = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).getSingle();
    expect(logRow.status, equals('timeout'));
    expect(logRow.errorMessage, contains('LOW_MEMORY'));
    expect(logRow.errorMessage, contains('Process killed by Android Low Memory Killer'));
  });

  test('recoverStuckTasks auto-reschedules when a resumable checkpoint is present', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final scratchDir = Workspace.instance.scratchDir;

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Resumable Task',
        type: 'one_off',
        status: 'running',
        payloadJson: '{}',
        startsAt: now - 600000,
        timezone: 'UTC',
        createdAt: now - 600000,
        updatedAt: now - 600000,
      ),
    );

    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 600000,
        status: 'running',
        lastHeartbeatAt: Value(now - 200000),
        currentStep: const Value('turn 3 · tool websearch'),
        createdAt: now - 600000,
        updatedAt: now - 200000,
      ),
    );

    // Save checkpoint at turn 3 with resumeCount 0
    final checkpoint = TaskCheckpoint(
      taskId: taskId,
      turn: 3,
      resumeCount: 0,
      updatedAt: now - 200000,
      messages: [
        {'role': 'user', 'content': 'prompt'}
      ],
    );
    await checkpoint.save(scratchDir);

    final scheduler = _ExitReasonScheduler(
      database: db,
      notificationService: mockNotifs,
      mockExitReasons: [
        {
          'reason': 2,
          'reasonName': 'SIGNALED',
          'description': 'SIGKILL',
          'timestamp': now - 195000,
        }
      ],
    );

    final recoveredCount = await scheduler.recoverStuckTasks();
    expect(recoveredCount, equals(1));

    // Must be auto-rescheduled for immediate resume (+30s), not failed
    final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    expect(taskRow.status, equals('scheduled'));
    expect(taskRow.nextRunAt, greaterThan(now));
    expect(scheduler.scheduled, contains(taskId));

    // Log records exit reason and checkpoint resume notice
    final logRow = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).getSingle();
    expect(logRow.status, equals('timeout'));
    expect(logRow.errorMessage, contains('SIGNALED'));
    expect(logRow.errorMessage, contains('Resuming from checkpoint (turn 3)'));
  });

  test('resume attempts are capped across recoveries via sidecar counter', () async {
    // The cap must survive fresh starts: a counter inside the checkpoint file
    // would reset when the file is deleted, letting an always-crashing task
    // cycle forever. Pre-seed two attempts, then recover: the task must take
    // the normal path (one_off -> failed), and the checkpoint must be gone.
    final now = DateTime.now().millisecondsSinceEpoch;
    final scratchDir = Workspace.instance.scratchDir;

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Capped Task',
        type: 'one_off',
        status: 'running',
        payloadJson: '{}',
        startsAt: now - 600000,
        timezone: 'UTC',
        createdAt: now - 600000,
        updatedAt: now - 600000,
      ),
    );

    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 600000,
        status: 'running',
        lastHeartbeatAt: Value(now - 200000),
        currentStep: const Value('turn 3 · tool websearch'),
        createdAt: now - 600000,
        updatedAt: now - 200000,
      ),
    );

    final checkpoint = TaskCheckpoint(
      taskId: taskId,
      turn: 3,
      resumeCount: 0,
      updatedAt: now - 200000,
      messages: [
        {'role': 'user', 'content': 'prompt'}
      ],
    );
    await checkpoint.save(scratchDir);
    expect(await TaskCheckpoint.noteResumeAttempt(taskId, scratchDir), equals(1));
    expect(await TaskCheckpoint.noteResumeAttempt(taskId, scratchDir), equals(2));

    final scheduler = _ExitReasonScheduler(
      database: db,
      notificationService: mockNotifs,
    );

    final recoveredCount = await scheduler.recoverStuckTasks();
    expect(recoveredCount, equals(1));

    final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    expect(taskRow.status, equals('failed'));
    expect(
      await TaskCheckpoint.load(taskId, scratchDir),
      isNull,
      reason: 'exhausted cap must clean up so cycling stops',
    );
  });
}
