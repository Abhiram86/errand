import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/tools/schedule_task_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ErrandDatabase db;

  setUp(() {
    db = ErrandDatabase.inMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('scheduleTaskTool', () {
    test('create one-off task with starts_at ISO string', () async {
      final tool = scheduleTaskTool(db: db);

      final startsAt =
          DateTime.now().add(const Duration(minutes: 5)).toIso8601String();
      final result = await tool.handler(
        ToolCall(
          id: 'call-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Remind to drink water',
            'prompt': 'Send a friendly reminder to hydrate',
            'schedule_type': 'one_off',
            'starts_at': startsAt,
            'notify': true,
          },
        ),
      );

      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      expect(data['status'], equals('created'));
      expect(data['task']['title'], equals('Remind to drink water'));
      expect(data['task']['type'], equals('one_off'));
      expect(data['task']['status'], equals('scheduled'));
      expect(data['task']['notify'], isTrue);
      expect(data['task']['repeat_after'], isNull);
      expect(data['task']['payload']['prompt'], equals('Send a friendly reminder to hydrate'));
    });

    test('create one-off task with delay_seconds', () async {
      final tool = scheduleTaskTool(db: db);
      final before = DateTime.now().millisecondsSinceEpoch;

      final result = await tool.handler(
        const ToolCall(
          id: 'call-delay-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Delayed reminder',
            'prompt': 'Check the oven',
            'schedule_type': 'one_off',
            'delay_seconds': 300,
          },
        ),
      );

      final after = DateTime.now().millisecondsSinceEpoch;
      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      final startsAt = data['task']['starts_at'] as int;
      expect(startsAt, greaterThanOrEqualTo(before + 300000));
      expect(startsAt, lessThanOrEqualTo(after + 300000 + 1000));
    });

    test('create recurring task with repeat_after', () async {
      final tool = scheduleTaskTool(db: db);

      final result = await tool.handler(
        const ToolCall(
          id: 'call-2',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Morning news brief',
            'prompt': 'Summarize top tech news',
            'schedule_type': 'recurring',
            'repeat_after': 86400000,
            'notify': true,
          },
        ),
      );

      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      expect(data['task']['repeat_after'], equals(86400000));
      expect(data['task']['type'], equals('recurring'));
    });

    test('create recurring fails without repeat_after', () async {
      final tool = scheduleTaskTool(db: db);

      final result = await tool.handler(
        const ToolCall(
          id: 'call-3',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Invalid recurring',
            'prompt': 'Check status',
            'schedule_type': 'recurring',
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.message, contains('repeat_after'));
    });

    test('get task by id', () async {
      final tool = scheduleTaskTool(db: db);

      final createRes = await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Task to get',
            'prompt': 'Run test',
            'schedule_type': 'one_off',
          },
        ),
      );
      final created = jsonDecode(createRes.output)['task'];
      final id = created['id'];

      final getRes = await tool.handler(
        ToolCall(
          id: 'g-1',
          name: 'schedule_task',
          arguments: {
            'action': 'get',
            'id': id,
          },
        ),
      );

      expect(getRes.ok, isTrue);
      final fetched = jsonDecode(getRes.output)['task'];
      expect(fetched['id'], equals(id));
      expect(fetched['title'], equals('Task to get'));
    });

    test('edit task', () async {
      final tool = scheduleTaskTool(db: db);

      final createRes = await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Initial title',
            'prompt': 'Initial prompt',
            'schedule_type': 'one_off',
          },
        ),
      );
      final id = jsonDecode(createRes.output)['task']['id'];

      final editRes = await tool.handler(
        ToolCall(
          id: 'e-1',
          name: 'schedule_task',
          arguments: {
            'action': 'edit',
            'id': id,
            'title': 'Updated title',
            'prompt': 'Updated prompt',
            'status': 'paused',
          },
        ),
      );

      expect(editRes.ok, isTrue);
      final updated = jsonDecode(editRes.output)['task'];
      expect(updated['title'], equals('Updated title'));
      expect(updated['payload']['prompt'], equals('Updated prompt'));
      expect(updated['status'], equals('paused'));
      expect(updated['next_run_at'], isNull);
    });

    test('delete task and cascade logs', () async {
      final tool = scheduleTaskTool(db: db);

      final createRes = await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'To be deleted',
            'prompt': 'Delete me',
            'schedule_type': 'one_off',
          },
        ),
      );
      final taskId = jsonDecode(createRes.output)['task']['id'] as int;

      // Insert a log directly
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'completed',
          createdAt: now,
          updatedAt: now,
        ),
      );

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

      // Verify task and log are gone
      final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingleOrNull();
      expect(task, isNull);

      final logs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logs, isEmpty);
    });

    test('list tasks with filter', () async {
      final tool = scheduleTaskTool(db: db);

      await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Active 1',
            'prompt': 'P1',
            'schedule_type': 'one_off',
          },
        ),
      );

      final c2 = await tool.handler(
        const ToolCall(
          id: 'c-2',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Active 2',
            'prompt': 'P2',
            'schedule_type': 'one_off',
          },
        ),
      );
      final id2 = jsonDecode(c2.output)['task']['id'];
      await tool.handler(
        ToolCall(
          id: 'e-1',
          name: 'schedule_task',
          arguments: {
            'action': 'edit',
            'id': id2,
            'status': 'paused',
          },
        ),
      );

      final listAll = await tool.handler(
        const ToolCall(
          id: 'l-1',
          name: 'schedule_task',
          arguments: {'action': 'list'},
        ),
      );
      final allData = jsonDecode(listAll.output);
      expect(allData['count'], equals(2));

      final listPaused = await tool.handler(
        const ToolCall(
          id: 'l-2',
          name: 'schedule_task',
          arguments: {
            'action': 'list',
            'status_filter': 'paused',
          },
        ),
      );
      final pausedData = jsonDecode(listPaused.output);
      expect(pausedData['count'], equals(1));
      expect(pausedData['tasks'][0]['status'], equals('paused'));
    });

    test('fetch task logs', () async {
      final tool = scheduleTaskTool(db: db);

      final c = await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Task with logs',
            'prompt': 'Prompt',
            'schedule_type': 'one_off',
          },
        ),
      );
      final taskId = jsonDecode(c.output)['task']['id'] as int;

      final now = DateTime.now().millisecondsSinceEpoch;
      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          summary: const Value('Report summary test'),
          outputFilePath: const Value('/scratch/task_report.md'),
          createdAt: now,
          updatedAt: now,
        ),
      );

      final logsRes = await tool.handler(
        ToolCall(
          id: 'log-1',
          name: 'schedule_task',
          arguments: {
            'action': 'logs',
            'id': taskId,
          },
        ),
      );

      expect(logsRes.ok, isTrue);
      final logsData = jsonDecode(logsRes.output);
      expect(logsData['count'], equals(1));
      expect(logsData['logs'][0]['summary'], equals('Report summary test'));
      expect(logsData['logs'][0]['output_file_path'], equals('/scratch/task_report.md'));
    });
  });
}
