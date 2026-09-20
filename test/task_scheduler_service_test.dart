import 'dart:io';

import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/tools/schedule_task_tool.dart';
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
}
