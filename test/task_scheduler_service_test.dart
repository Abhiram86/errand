import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/tools/schedule_task_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
