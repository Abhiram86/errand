import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/notification_service.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/tools/schedule_task_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MockNotificationService extends NotificationService {
  final List<Map<String, dynamic>> shownNotifications = [];

  @override
  Future<bool> showNotification({
    required int id,
    required String title,
    required String body,
    String channelId = 'scheduled_tasks',
    String channelName = 'Scheduled Tasks',
    bool? isSuccess,
  }) async {
    shownNotifications.add({
      'id': id,
      'title': title,
      'body': body,
      'isSuccess': isSuccess,
    });
    return true;
  }
}

class TrackingSchedulerService extends TaskSchedulerService {
  final List<int> scheduledTasks = [];
  final List<int> cancelledTasks = [];
  final List<int> executedTasks = [];

  TrackingSchedulerService({
    super.database,
    super.notificationService,
  });

  @override
  Future<void> scheduleTask(int taskId) async {
    scheduledTasks.add(taskId);
  }

  @override
  Future<void> cancelTask(int taskId) async {
    cancelledTasks.add(taskId);
  }

  @override
  Future<bool> executeTask(
    int taskId, {
    AgentRunner? runner,
    Directory? scratchDirectory,
    Duration timeout = const Duration(minutes: 10),
    dynamic cancelToken,
  }) async {
    executedTasks.add(taskId);
    return true;
  }
}

void main() {
  late ErrandDatabase db;
  late TrackingSchedulerService scheduler;

  setUp(() {
    db = ErrandDatabase.inMemory();
    scheduler = TrackingSchedulerService(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  test('scheduleTaskTool invokes scheduleTask on create', () async {
    final tool = scheduleTaskTool(
      db: db,
      schedulerService: scheduler,
    );

    final res = await tool.handler(
      const ToolCall(
        id: 'c-1',
        name: 'schedule_task',
        arguments: {
          'action': 'create',
          'title': 'Test Task',
          'prompt': 'Do something',
          'schedule_type': 'one_off',
        },
      ),
    );

    expect(res.ok, isTrue);
    expect(scheduler.scheduledTasks.length, equals(1));
    expect(scheduler.cancelledTasks, isEmpty);
  });

  test('scheduleTaskTool invokes cancelTask on delete', () async {
    final tool = scheduleTaskTool(
      db: db,
      schedulerService: scheduler,
    );

    await tool.handler(
      const ToolCall(
        id: 'c-1',
        name: 'schedule_task',
        arguments: {
          'action': 'create',
          'title': 'Task to delete',
          'prompt': 'Run something',
          'schedule_type': 'one_off',
        },
      ),
    );
    final taskId = (await (db.select(db.schedulerTasks)).getSingle()).id;

    final delRes = await tool.handler(
      ToolCall(
        id: 'd-1',
        name: 'schedule_task',
        arguments: {
          'action': 'delete',
          'id': taskId,
        },
      ),
    );

    expect(delRes.ok, isTrue);
    expect(scheduler.cancelledTasks, contains(taskId));
  });

  test('scheduleTaskTool invokes cancelTask on edit when paused or cancelled', () async {
    final tool = scheduleTaskTool(
      db: db,
      schedulerService: scheduler,
    );

    await tool.handler(
      const ToolCall(
        id: 'c-1',
        name: 'schedule_task',
        arguments: {
          'action': 'create',
          'title': 'Task to pause',
          'prompt': 'Run something',
          'schedule_type': 'one_off',
        },
      ),
    );
    final taskId = (await (db.select(db.schedulerTasks)).getSingle()).id;

    scheduler.scheduledTasks.clear();

    await tool.handler(
      ToolCall(
        id: 'e-1',
        name: 'schedule_task',
        arguments: {
          'action': 'edit',
          'id': taskId,
          'status': 'paused',
        },
      ),
    );

    expect(scheduler.cancelledTasks, contains(taskId));
    expect(scheduler.scheduledTasks, isEmpty);
  });

  test('scheduleTaskTool invokes scheduleTask on edit when resumed/scheduled', () async {
    final tool = scheduleTaskTool(
      db: db,
      schedulerService: scheduler,
    );

    await tool.handler(
      const ToolCall(
        id: 'c-1',
        name: 'schedule_task',
        arguments: {
          'action': 'create',
          'title': 'Task to update',
          'prompt': 'Initial prompt',
          'schedule_type': 'one_off',
        },
      ),
    );
    final taskId = (await (db.select(db.schedulerTasks)).getSingle()).id;

    scheduler.scheduledTasks.clear();

    await tool.handler(
      ToolCall(
        id: 'e-1',
        name: 'schedule_task',
        arguments: {
          'action': 'edit',
          'id': taskId,
          'title': 'Updated title',
        },
      ),
    );

    expect(scheduler.scheduledTasks, contains(taskId));
  });

  group('TaskSchedulerService native channel tests', () {
    late ErrandDatabase serviceDb;
    late TaskSchedulerService realService;
    final List<MethodCall> channelCalls = [];

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      serviceDb = ErrandDatabase.inMemory();
      realService = TaskSchedulerService(database: serviceDb);
      channelCalls.clear();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('task_scheduler'), (call) async {
        channelCalls.add(call);
        if (call.method == 'scheduleAlarm') {
          return true;
        } else if (call.method == 'cancelAlarm') {
          return true;
        } else if (call.method == 'canScheduleExactAlarms') {
          return true;
        }
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('task_scheduler'), null);
      await serviceDb.close();
    });

    test('scheduleTask invokes scheduleAlarm method on task_scheduler channel', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Daily Backup',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 60000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      await realService.scheduleTask(taskId);

      expect(channelCalls.length, equals(1));
      expect(channelCalls.first.method, equals('scheduleAlarm'));
      final args = channelCalls.first.arguments as Map;
      expect(args['taskId'], equals(taskId));
      expect(args['title'], equals('Daily Backup'));
      expect(args['triggerAtMillis'], equals(nowMillis + 60000));
    });

    test('scheduleTask clamps past triggers to ~1s in the future', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final taskId = await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Overdue task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: before - 60000,
          nextRunAt: Value(before - 60000),
          timezone: 'UTC',
          createdAt: before - 60000,
          updatedAt: before - 60000,
        ),
      );

      await realService.scheduleTask(taskId);

      expect(channelCalls.length, equals(1));
      final args = channelCalls.first.arguments as Map;
      final trigger = args['triggerAtMillis'] as int;
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(trigger, greaterThanOrEqualTo(before + 1000));
      expect(trigger, lessThanOrEqualTo(after + 1000));
    });

    test('concurrent rescheduleAllActiveTasks share a single run', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;

      await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Shared Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 10000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final results = await Future.wait([
        realService.rescheduleAllActiveTasks(),
        realService.rescheduleAllActiveTasks(),
      ]);

      expect(results, equals([1, 1]));
      final alarms = channelCalls.where((c) => c.method == 'scheduleAlarm').toList();
      expect(alarms.length, equals(1));
    });

    test('cancelTask invokes cancelAlarm method on task_scheduler channel', () async {
      await realService.cancelTask(42);

      expect(channelCalls.length, equals(1));
      expect(channelCalls.first.method, equals('cancelAlarm'));
      final args = channelCalls.first.arguments as Map;
      expect(args['taskId'], equals(42));
    });

    test('canScheduleExactAlarms queries task_scheduler channel', () async {
      final canSchedule = await realService.canScheduleExactAlarms();
      expect(canSchedule, isTrue);
      expect(channelCalls.any((c) => c.method == 'canScheduleExactAlarms'), isTrue);
    });

    test('unreadNotificationCount counts only unseen execution logs', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Unread count task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: nowMillis,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      for (final seen in [0, 0, 1]) {
        await serviceDb.into(serviceDb.schedulerTaskLogs).insert(
          SchedulerTaskLogsCompanion.insert(
            schedulerTaskId: taskId,
            scheduledFor: nowMillis,
            status: 'success',
            createdAt: nowMillis,
            updatedAt: nowMillis,
            notificationSeen: Value(seen),
          ),
        );
      }

      expect(await realService.unreadNotificationCount(), equals(2));
    });

    test('rescheduleAllActiveTasks schedules all active tasks and recovers stuck ones', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;

      final t1 = await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Task 1',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 10000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final t2 = await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Task 2',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 20000,
          repeatAfter: const Value(3600000),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      // Also an un-scheduled one that should be ignored
      await serviceDb.into(serviceDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Paused Task',
          type: 'one_off',
          status: 'paused',
          payloadJson: '{}',
          startsAt: nowMillis + 30000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final count = await realService.rescheduleAllActiveTasks();
      expect(count, equals(2));

      final scheduledIds = channelCalls
          .where((c) => c.method == 'scheduleAlarm')
          .map((c) => (c.arguments as Map)['taskId'])
          .toList();

      expect(scheduledIds, containsAll([t1, t2]));
    });

    test('initialize registers MethodCallHandler for executeTask and rescheduleAll', () async {
      realService.initialize();

      // We can simulate an incoming call from native Android to task_scheduler channel
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();

      // Test rescheduleAll callback
      final rescheduleCall = codec.encodeMethodCall(const MethodCall('rescheduleAll'));
      final rescheduleReply = Completer<ByteData?>();
      await messenger.handlePlatformMessage('task_scheduler', rescheduleCall, (data) {
        rescheduleReply.complete(data);
      });
      final replyData = await rescheduleReply.future;
      expect(replyData, isNotNull);
      final rescheduleResult = codec.decodeEnvelope(replyData!);
      expect(rescheduleResult, isA<int>());
    });

    test('getPendingNotificationClick memoizes and overlaps lookup, clear resets', () async {
      int invokeCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('task_scheduler'), (call) async {
        if (call.method == 'getPendingNotificationClick') {
          invokeCount++;
          return {'taskId': 42, 'route': 'manage_tasks_unread'};
        }
        return true;
      });

      realService.clearPendingNotificationClick();
      // initialize starts lookup non-blocking
      realService.initialize();

      // First call awaits the already in-flight lookup
      final res1 = await realService.getPendingNotificationClick();
      expect(res1, equals({'taskId': 42, 'route': 'manage_tasks_unread'}));
      expect(invokeCount, equals(1));

      // Second call reuses memoized future without another channel invoke
      final res2 = await realService.getPendingNotificationClick();
      expect(res2, equals({'taskId': 42, 'route': 'manage_tasks_unread'}));
      expect(invokeCount, equals(1));

      // Clear resets future
      realService.clearPendingNotificationClick();
      final res3 = await realService.getPendingNotificationClick();
      expect(res3, equals({'taskId': 42, 'route': 'manage_tasks_unread'}));
      expect(invokeCount, equals(2));
    });

    test('pauseAllTasks transitions scheduled tasks to paused and cancels alarms', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final t1 = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Task 1',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 10000,
          repeatAfter: const Value(3600000),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
      final t2 = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Task 2',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis + 20000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
      final tCompleted = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Completed Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: nowMillis - 10000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final count = await scheduler.pauseAllTasks();
      expect(count, equals(2));
      expect(scheduler.cancelledTasks, containsAll([t1, t2]));

      final row1 = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(t1))).getSingle();
      expect(row1.status, equals('paused'));

      final row2 = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(t2))).getSingle();
      expect(row2.status, equals('paused'));

      final rowComp = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(tCompleted))).getSingle();
      expect(rowComp.status, equals('completed'));
    });

    test('resumeAllTasks transitions paused tasks to scheduled and schedules alarms', () async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final t1 = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Paused Recurring Task',
          type: 'recurring',
          status: 'paused',
          payloadJson: '{}',
          startsAt: nowMillis - 50000,
          repeatAfter: const Value(3600000),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
      final t2 = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Paused One-Off Task',
          type: 'one_off',
          status: 'paused',
          payloadJson: '{}',
          startsAt: nowMillis + 30000,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final count = await scheduler.resumeAllTasks();
      expect(count, equals(2));
      expect(scheduler.scheduledTasks, containsAll([t1, t2]));

      final row1 = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(t1))).getSingle();
      expect(row1.status, equals('scheduled'));
      expect(row1.nextRunAt, greaterThan(nowMillis));

      final row2 = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(t2))).getSingle();
      expect(row2.status, equals('scheduled'));
      expect(row2.nextRunAt, equals(nowMillis + 30000));
    });

    test('pauseAllTasks and resumeAllTasks return 0 when no tasks match', () async {
      expect(await scheduler.pauseAllTasks(), equals(0));
      expect(await scheduler.resumeAllTasks(), equals(0));
    });

    test('calculateNextRunAt strict grid Option A arithmetic', () {
      const startsAt = 1000000;
      const repeatAfter = 3600000; // 1 hour

      // Before start time
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt - 500,
        ),
        equals(startsAt),
      );

      // Exactly at start time
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt,
        ),
        equals(startsAt + repeatAfter),
      );

      // Normal execution duration (e.g. 45s after start) does not drift next run
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt + 45000,
        ),
        equals(startsAt + repeatAfter),
      );

      // Mid-cycle run (e.g. 30m after start) still snaps to next 1h slot
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt + 1800000,
        ),
        equals(startsAt + repeatAfter),
      );

      // Option A strict grid: run triggered right before next slot (e.g. 55m after start)
      // still targets the upcoming 1h slot
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt + 3300000,
        ),
        equals(startsAt + repeatAfter),
      );

      // Multiple intervals passed (e.g. device off for 3.5 hours)
      expect(
        TaskSchedulerService.calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: repeatAfter,
          nowMillis: startsAt + (3.5 * repeatAfter).toInt(),
        ),
        equals(startsAt + 4 * repeatAfter),
      );
    });

    test('recoverStuckTasks notifies on fresh kill and reschedules recurring task without drift', () async {
      final mockNotifs = MockNotificationService();
      final stuckDb = ErrandDatabase.inMemory();
      final stuckScheduler = TrackingSchedulerService(
        database: stuckDb,
        notificationService: mockNotifs,
      );

      final now = DateTime.now().millisecondsSinceEpoch;

      // Task 1: Stuck recurring task with notify = true, killed 20 mins ago (fresh kill)
      final t1 = await stuckDb.into(stuckDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Fresh Kill Recurring Task',
          type: 'recurring',
          status: 'running',
          payloadJson: '{}',
          startsAt: now - 3600000, // 1h ago
          repeatAfter: const Value(3600000), // 1h interval
          timezone: 'UTC',
          notify: const Value(true),
          createdAt: now - 3600000,
          updatedAt: now - 1200000, // 20m ago (> 15m cutoff, but < 4h freshCutoff)
        ),
      );

      await stuckDb.into(stuckDb.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: t1,
          scheduledFor: now - 3600000,
          status: 'running',
          createdAt: now - 3600000,
          updatedAt: now - 1200000,
        ),
      );

      // Task 2: Stale stuck task killed 10 hours ago (beyond 4h freshKillWindow)
      final t2 = await stuckDb.into(stuckDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Stale Kill Task',
          type: 'one_off',
          status: 'running',
          payloadJson: '{}',
          startsAt: now - 36000000, // 10h ago
          timezone: 'UTC',
          notify: const Value(true),
          createdAt: now - 36000000,
          updatedAt: now - 36000000, // 10h ago
        ),
      );

      await stuckDb.into(stuckDb.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: t2,
          scheduledFor: now - 36000000,
          status: 'running',
          createdAt: now - 36000000,
          updatedAt: now - 36000000,
        ),
      );

      // Task 3: Stuck task with notify = false
      final t3 = await stuckDb.into(stuckDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Silent Stuck Task',
          type: 'one_off',
          status: 'running',
          payloadJson: '{}',
          startsAt: now - 1800000, // 30m ago
          timezone: 'UTC',
          notify: const Value(false),
          createdAt: now - 1800000,
          updatedAt: now - 1800000,
        ),
      );

      await stuckDb.into(stuckDb.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: t3,
          scheduledFor: now - 1800000,
          status: 'running',
          createdAt: now - 1800000,
          updatedAt: now - 1800000,
        ),
      );

      final recovered = await stuckScheduler.recoverStuckTasks();
      expect(recovered, equals(3));

      // Notification should ONLY be dispatched for t1 (fresh kill + notify: true)
      expect(mockNotifs.shownNotifications.length, equals(1));
      final notif = mockNotifs.shownNotifications.first;
      expect(notif['id'], equals(t1));
      expect(notif['title'], contains('Fresh Kill Recurring Task'));
      expect(notif['title'], contains('Interrupted'));
      expect(notif['isSuccess'], isFalse);

      // Check t1 row was rescheduled to scheduled on the grid
      final row1 = await (stuckDb.select(stuckDb.schedulerTasks)..where((t) => t.id.equals(t1))).getSingle();
      expect(row1.status, equals('scheduled'));
      expect(row1.nextRunAt, greaterThan(now));
      // Anchor alignment: nextRunAt must equal startsAt + n * repeatAfter
      expect((row1.nextRunAt! - (now - 3600000)) % 3600000, equals(0));

      // Logs for all 3 must be transitioned to 'timeout'
      final logs = await (stuckDb.select(stuckDb.schedulerTaskLogs)).get();
      for (final log in logs) {
        expect(log.status, equals('timeout'));
        expect(log.errorMessage, contains('interrupted or killed'));
      }

      await stuckDb.close();
    });
  });
}
