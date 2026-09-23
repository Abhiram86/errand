import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/services/task_toast_service.dart';
import 'package:errand/tools/schedule_task_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ErrandDatabase db;
  late TaskSchedulerService scheduler;

  setUp(() {
    db = ErrandDatabase.inMemory();
    scheduler = TaskSchedulerService(database: db);
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

    test('create, edit, and delete fire TaskToastService events directly', () async {
      final events = <TaskToastEvent>[];
      final sub = TaskToastService.instance.stream.listen(events.add);

      final tool = scheduleTaskTool(db: db);

      // 1. Create
      final createResult = await tool.handler(
        const ToolCall(
          id: 'call-toast-create',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Toast Showcase Task',
            'prompt': 'Show notification toast',
            'schedule_type': 'one_off',
            'delay_seconds': 60,
          },
        ),
      );
      await pumpEventQueue();
      expect(createResult.ok, isTrue);
      expect(events.length, equals(1));
      expect(events.last.type, equals(TaskToastType.create));
      expect(events.last.message, contains('Toast Showcase Task'));
      final taskId = events.last.taskId!;

      // 2. Edit
      final editResult = await tool.handler(
        ToolCall(
          id: 'call-toast-edit',
          name: 'schedule_task',
          arguments: {
            'action': 'edit',
            'id': taskId,
            'title': 'Updated Toast Task',
          },
        ),
      );
      await pumpEventQueue();
      expect(editResult.ok, isTrue);
      expect(events.length, equals(2));
      expect(events.last.type, equals(TaskToastType.edit));
      expect(events.last.message, contains('Updated Toast Task'));

      // 3. Delete
      final deleteResult = await tool.handler(
        ToolCall(
          id: 'call-toast-delete',
          name: 'schedule_task',
          arguments: {
            'action': 'delete',
            'id': taskId,
          },
        ),
      );
      await pumpEventQueue();
      expect(deleteResult.ok, isTrue);
      expect(events.length, equals(3));
      expect(events.last.type, equals(TaskToastType.delete));
      expect(events.last.message, contains('deleted'));

      await sub.cancel();
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

    test('create one-off task with epoch seconds parses into milliseconds', () async {
      final tool = scheduleTaskTool(db: db);

      // Pass 10-digit epoch seconds (e.g. 1750000000)
      final result = await tool.handler(
        const ToolCall(
          id: 'call-sec-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Epoch seconds reminder',
            'prompt': 'Check seconds conversion',
            'schedule_type': 'one_off',
            'starts_at': '1750000000',
          },
        ),
      );

      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      final startsAt = data['task']['starts_at'] as int;
      // Should be scaled to milliseconds (13 digits: 1750000000000)
      expect(startsAt, equals(1750000000000));
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

    test('edit task updates next_run_at when status is not passed', () async {
      final tool = scheduleTaskTool(db: db);

      final createRes = await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Active one_off',
            'prompt': 'Prompt 1',
            'schedule_type': 'one_off',
            'delay_seconds': 60,
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
            'delay_seconds': 600, // 10 minutes delay
          },
        ),
      );

      expect(editRes.ok, isTrue);
      final updated = jsonDecode(editRes.output)['task'];
      final nextRunAt = updated['next_run_at'] as int;
      final startsAt = updated['starts_at'] as int;
      expect(nextRunAt, equals(startsAt));
      expect(nextRunAt, greaterThan(DateTime.now().millisecondsSinceEpoch + 500000));
    });

    test('edit recurring task with past start advances next_run_at by repeat_after interval', () async {
      final tool = scheduleTaskTool(db: db);
      final now = DateTime.now().millisecondsSinceEpoch;

      final createRes = await tool.handler(
        ToolCall(
          id: 'c-rec',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Hourly news',
            'prompt': 'Fetch news',
            'schedule_type': 'recurring',
            'starts_at': (now + 3600000).toString(),
            'repeat_after': 3600000,
          },
        ),
      );
      final id = jsonDecode(createRes.output)['task']['id'];

      // Edit with a past start_at (30 minutes ago) and 1 hour repeat
      final pastTime = now - 1800000;
      final editRes = await tool.handler(
        ToolCall(
          id: 'e-rec',
          name: 'schedule_task',
          arguments: {
            'action': 'edit',
            'id': id,
            'starts_at': pastTime.toString(),
            'repeat_after': 3600000,
          },
        ),
      );

      expect(editRes.ok, isTrue);
      final updated = jsonDecode(editRes.output)['task'];
      final nextRunAt = updated['next_run_at'] as int;
      // nextRunAt should be pastTime + 3600000 = now + 1800000 (30 min in future)
      expect(nextRunAt, equals(pastTime + 3600000));
      expect(nextRunAt, greaterThan(now));
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

    test('create stores model and provider overrides in payload', () async {
      final tool = scheduleTaskTool(db: db);
      final result = await tool.handler(
        ToolCall(
          id: 'ovr-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Override task',
            'prompt': 'Do work',
            'schedule_type': 'one_off',
            'delay_seconds': 60,
            'model': 'google/gemini-2.0-flash',
            'provider_id': 'openrouter',
          },
        ),
      );

      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      expect(data['task']['payload']['model'], equals('google/gemini-2.0-flash'));
      expect(data['task']['payload']['providerId'], equals('openrouter'));
    });

    test('edit rejects invalid status and schedule_type', () async {
      final tool = scheduleTaskTool(db: db);
      final createRes = await tool.handler(
        const ToolCall(
          id: 'inv-0',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Validation task',
            'prompt': 'Do work',
            'schedule_type': 'one_off',
          },
        ),
      );
      expect(createRes.ok, isTrue);
      final taskId = (jsonDecode(createRes.output) as Map)['task']['id'];

      final badStatus = await tool.handler(
        ToolCall(
          id: 'inv-1',
          name: 'schedule_task',
          arguments: {'action': 'edit', 'id': taskId, 'status': 'bogus'},
        ),
      );
      expect(badStatus.ok, isFalse);
      expect(badStatus.errorMessage ?? badStatus.output, contains('Invalid "status"'));

      final badType = await tool.handler(
        ToolCall(
          id: 'inv-2',
          name: 'schedule_task',
          arguments: {'action': 'edit', 'id': taskId, 'schedule_type': 'sometimes'},
        ),
      );
      expect(badType.ok, isFalse);
      expect(badType.errorMessage ?? badType.output, contains('Invalid "schedule_type"'));
    });

    test('create coerces numeric-string and double args instead of throwing', () async {
      final tool = scheduleTaskTool(db: db);
      final result = await tool.handler(
        ToolCall(
          id: 'coerce-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Coerced task',
            'prompt': 'Do work',
            'schedule_type': 'one_off',
            'delay_seconds': 300.0,
            'notify': 'true',
          },
        ),
      );

      expect(result.ok, isTrue);
      final data = jsonDecode(result.output) as Map<String, dynamic>;
      expect(data['task']['notify'], isTrue);
    });

    test('pause_all and resume_all actions pause and resume tasks via scheduler', () async {
      final tool = scheduleTaskTool(db: db, schedulerService: scheduler);

      await tool.handler(
        const ToolCall(
          id: 'c-1',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Task 1',
            'prompt': 'Run test',
            'schedule_type': 'one_off',
          },
        ),
      );
      await tool.handler(
        const ToolCall(
          id: 'c-2',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Task 2',
            'prompt': 'Run test 2',
            'schedule_type': 'recurring',
            'repeat_after': 3600000,
          },
        ),
      );

      final pauseRes = await tool.handler(
        const ToolCall(
          id: 'p-all',
          name: 'schedule_task',
          arguments: {'action': 'pause_all'},
        ),
      );
      expect(pauseRes.ok, isTrue);
      final pauseData = jsonDecode(pauseRes.output);
      expect(pauseData['status'], equals('paused_all'));
      expect(pauseData['count'], equals(2));

      final resumeRes = await tool.handler(
        const ToolCall(
          id: 'r-all',
          name: 'schedule_task',
          arguments: {'action': 'resume_all'},
        ),
      );
      expect(resumeRes.ok, isTrue);
      final resumeData = jsonDecode(resumeRes.output);
      expect(resumeData['status'], equals('resumed_all'));
      expect(resumeData['count'], equals(2));
    });

    test('headless mode blocks pause_all and resume_all', () async {
      final headlessTool = scheduleTaskTool(db: db, isHeadless: true);

      final pauseRes = await headlessTool.handler(
        const ToolCall(
          id: 'p-1',
          name: 'schedule_task',
          arguments: {'action': 'pause_all'},
        ),
      );
      expect(pauseRes.ok, isFalse);
      expect(pauseRes.error?.type, equals('headless_recursion_blocked'));

      final resumeRes = await headlessTool.handler(
        const ToolCall(
          id: 'r-1',
          name: 'schedule_task',
          arguments: {'action': 'resume_all'},
        ),
      );
      expect(resumeRes.ok, isFalse);
      expect(resumeRes.error?.type, equals('headless_recursion_blocked'));
    });
  });
}
