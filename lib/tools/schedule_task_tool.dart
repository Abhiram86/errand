import 'dart:convert';

import 'package:drift/drift.dart';

import '../agent/tool.dart';
import '../services/database.dart';
import '../services/task_scheduler_service.dart';
import '../types/tool.dart';

/// Tool allowing the agent to create, edit, inspect, and manage background
/// scheduled tasks and their execution logs.
Tool scheduleTaskTool({
  ErrandDatabase? db,
  TaskSchedulerService? schedulerService,
  bool isHeadless = false,
  int? currentTaskId,
}) {
  return Tool(
    name: 'schedule_task',
    description:
        'Schedule and manage background autonomous tasks and reminders. '
        'Actions: '
        'create (schedule a new one-off or recurring task), '
        'edit (update title, prompt, timing, or status of an existing task), '
        'delete (remove a task and its run logs), '
        'get (retrieve task details by id), '
        'list (list tasks with optional status_filter, limit, offset), '
        'logs (view execution history logs for a task). '
        'For one-off tasks, specify starts_at (ISO 8601 string or epoch millis) or delay_seconds (e.g. 300 for 5m). '
        'For recurring tasks, specify repeat_after interval in millis (e.g. 900000 for 15m, 3600000 for 1h). '
        'The task will execute headlessly in the background, run agent tools, and save output to the scratch directory.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['create', 'edit', 'delete', 'get', 'list', 'logs'],
          'description': 'Discriminator action: create, edit, delete, get, list, logs.',
        },
        'id': {
          'type': 'string',
          'description': 'Task ID (integer or numeric string). Required for edit, delete, get, logs. Ignored for create and list.',
        },
        'title': {
          'type': 'string',
          'description': 'Human-readable name for the task. Required for create. Optional on edit.',
        },
        'schedule_type': {
          'type': 'string',
          'enum': ['one_off', 'recurring'],
          'description': 'Schedule type: one_off or recurring. Required for create. Optional on edit.',
        },
        'starts_at': {
          'type': 'string',
          'description': 'First run time: ISO 8601 string or epoch millis string. Optional on edit.',
        },
        'delay_seconds': {
          'type': 'integer',
          'description': 'Relative delay in seconds from now (e.g. 300 for 5 min, 1800 for 30 min, 3600 for 1 hr). Convenient alternative to starts_at.',
        },
        'repeat_after': {
          'type': 'integer',
          'description': 'Interval in milliseconds for recurring tasks (e.g. 900000 for 15m, 3600000 for 1h, 86400000 for 1d). Required for create when recurring. Optional on edit.',
        },
        'prompt': {
          'type': 'string',
          'description': 'The user instruction for the run. Tool packs it into payload internally. Required for create. Optional on edit.',
        },
        'notify': {
          'type': 'boolean',
          'default': true,
          'description': 'Whether to send a system notification on completion or failure. Default true. Optional on edit.',
        },
        'status': {
          'type': 'string',
          'enum': ['paused', 'scheduled', 'cancelled'],
          'description': 'Task lifecycle state. edit only.',
        },
        'status_filter': {
          'type': 'string',
          'enum': ['scheduled', 'paused', 'running', 'completed', 'failed', 'cancelled'],
          'description': 'Filter by task status. list only.',
        },
        'limit': {
          'type': 'integer',
          'default': 20,
          'description': 'Maximum number of entries to return. list and logs only. Default 20.',
        },
        'offset': {
          'type': 'integer',
          'default': 0,
          'description': 'Pagination offset. list and logs only. Default 0.',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      final database = db ?? ErrandDatabase.instance;
      TaskSchedulerService? scheduler = schedulerService;
      if (scheduler == null && db == null) {
        try {
          scheduler = TaskSchedulerService.instance;
        } catch (_) {}
      }
      final args = call.arguments;
      final action = ((args['action'] ?? args['type']) as String?)?.trim().toLowerCase() ?? '';

      if (isHeadless && (action == 'create' || action == 'delete')) {
        return ToolCallResult.failure(
          call.id,
          'Action "$action" is disabled in background scheduled tasks to prevent recursive scheduling loops.',
          type: 'headless_recursion_blocked',
        );
      }

      switch (action) {
        case 'create':
          final title = (args['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) {
            return ToolCallResult.failure(call.id, 'Action "create" requires a non-empty "title".');
          }

          final prompt = (args['prompt'] as String?)?.trim() ?? '';
          if (prompt.isEmpty) {
            return ToolCallResult.failure(call.id, 'Action "create" requires a non-empty "prompt".');
          }

          final scheduleType = (args['schedule_type'] as String?)?.trim().toLowerCase() ?? 'one_off';
          if (scheduleType != 'one_off' && scheduleType != 'recurring') {
            return ToolCallResult.failure(
              call.id,
              'Invalid "schedule_type": "$scheduleType". Expected "one_off" or "recurring".',
            );
          }

          final isRecurring = scheduleType == 'recurring';
          final repeatAfter = args['repeat_after'] as int?;
          if (isRecurring && (repeatAfter == null || repeatAfter <= 0)) {
            return ToolCallResult.failure(
              call.id,
              'Action "create" for recurring tasks requires a positive "repeat_after" interval in milliseconds (e.g. 900000 for 15m, 3600000 for 1h).',
            );
          }

          final nowMillis = DateTime.now().millisecondsSinceEpoch;
          int startsAtMillis;
          final delaySeconds = args['delay_seconds'] as int?;
          final startsAtRaw = args['starts_at'];

          if (delaySeconds != null && delaySeconds > 0) {
            startsAtMillis = nowMillis + (delaySeconds * 1000);
          } else if (startsAtRaw != null) {
            final parsed = _parseTimestampMillis(startsAtRaw);
            if (parsed == null) {
              return ToolCallResult.failure(
                call.id,
                'Invalid "starts_at" format: "$startsAtRaw". Expected ISO 8601 string or epoch milliseconds.',
              );
            }
            startsAtMillis = parsed;
          } else {
            // Default to 60 seconds from now
            startsAtMillis = nowMillis + 60000;
          }

          final notify = (args['notify'] as bool?) ?? true;
          final timezone = DateTime.now().timeZoneName;
          final payloadJson = jsonEncode({
            'prompt': prompt,
          });

          final taskId = await database.into(database.schedulerTasks).insert(
            SchedulerTasksCompanion.insert(
              title: title,
              type: scheduleType,
              status: 'scheduled',
              payloadJson: payloadJson,
              startsAt: startsAtMillis,
              nextRunAt: Value(startsAtMillis),
              repeatAfter: Value(isRecurring ? repeatAfter : null),
              timezone: timezone,
              notify: Value(notify),
              createdAt: nowMillis,
              updatedAt: nowMillis,
            ),
          );

          final insertedRow = await (database.select(database.schedulerTasks)
                ..where((t) => t.id.equals(taskId)))
              .getSingle();

          await scheduler?.scheduleTask(taskId);

          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'status': 'created',
              'task': _taskRowToMap(insertedRow),
            }),
          );

        case 'edit':
          final taskId = _parseId(args['id']);
          if (taskId == null) {
            return ToolCallResult.failure(call.id, 'Action "edit" requires a valid "id".');
          }

          if (isHeadless && (currentTaskId == null || taskId != currentTaskId)) {
            return ToolCallResult.failure(
              call.id,
              currentTaskId == null
                  ? 'Headless tasks cannot edit tasks without a recognized current task context.'
                  : 'Headless task can only edit its own task (id: $currentTaskId). Cannot modify task $taskId.',
              type: 'headless_cross_task_edit_blocked',
            );
          }

          final existing = await (database.select(database.schedulerTasks)
                ..where((t) => t.id.equals(taskId)))
              .getSingleOrNull();
          if (existing == null) {
            return ToolCallResult.failure(call.id, 'Task with id $taskId not found.');
          }

          final nowMillis = DateTime.now().millisecondsSinceEpoch;
          String newTitle = existing.title;
          if (args['title'] != null && (args['title'] as String).trim().isNotEmpty) {
            newTitle = (args['title'] as String).trim();
          }

          String newType = existing.type;
          if (args['schedule_type'] != null) {
            final st = (args['schedule_type'] as String).trim().toLowerCase();
            if (st == 'one_off' || st == 'recurring') {
              newType = st;
            }
          }

          int? newRepeatAfter = existing.repeatAfter;
          if (args.containsKey('repeat_after')) {
            newRepeatAfter = args['repeat_after'] as int?;
          }

          int newStartsAt = existing.startsAt;
          final editDelaySeconds = args['delay_seconds'] as int?;
          if (editDelaySeconds != null && editDelaySeconds > 0) {
            newStartsAt = nowMillis + (editDelaySeconds * 1000);
          } else if (args['starts_at'] != null) {
            final parsed = _parseTimestampMillis(args['starts_at']);
            if (parsed != null) newStartsAt = parsed;
          }

          String newPayloadJson = existing.payloadJson;
          if (args['prompt'] != null && (args['prompt'] as String).trim().isNotEmpty) {
            Map<String, dynamic> payloadMap;
            try {
              payloadMap = jsonDecode(existing.payloadJson) as Map<String, dynamic>;
            } catch (_) {
              payloadMap = {};
            }
            payloadMap['prompt'] = (args['prompt'] as String).trim();
            newPayloadJson = jsonEncode(payloadMap);
          }

          bool newNotify = existing.notify;
          if (args['notify'] != null) {
            newNotify = args['notify'] as bool;
          }

          String newStatus = existing.status;
          int? newNextRunAt = existing.nextRunAt;
          if (args['status'] != null) {
            final st = (args['status'] as String).trim().toLowerCase();
            if (st == 'paused' || st == 'scheduled' || st == 'cancelled') {
              newStatus = st;
              if (st == 'paused' || st == 'cancelled') {
                newNextRunAt = null;
              } else if (st == 'scheduled') {
                newNextRunAt = newStartsAt > nowMillis ? newStartsAt : nowMillis + 60000;
              }
            }
          }

          await (database.update(database.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
            SchedulerTasksCompanion(
              title: Value(newTitle),
              type: Value(newType),
              status: Value(newStatus),
              payloadJson: Value(newPayloadJson),
              startsAt: Value(newStartsAt),
              nextRunAt: Value(newNextRunAt),
              repeatAfter: Value(newRepeatAfter),
              notify: Value(newNotify),
              updatedAt: Value(nowMillis),
            ),
          );

          final updatedRow = await (database.select(database.schedulerTasks)
                ..where((t) => t.id.equals(taskId)))
              .getSingle();

          if (newStatus == 'paused' || newStatus == 'cancelled') {
            await scheduler?.cancelTask(taskId);
          } else {
            await scheduler?.scheduleTask(taskId);
          }

          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'status': 'updated',
              'task': _taskRowToMap(updatedRow),
            }),
          );

        case 'delete':
          final taskId = _parseId(args['id']);
          if (taskId == null) {
            return ToolCallResult.failure(call.id, 'Action "delete" requires a valid "id".');
          }

          final existing = await (database.select(database.schedulerTasks)
                ..where((t) => t.id.equals(taskId)))
              .getSingleOrNull();
          if (existing == null) {
            return ToolCallResult.failure(call.id, 'Task with id $taskId not found.');
          }

          await (database.delete(database.schedulerTasks)..where((t) => t.id.equals(taskId))).go();

          await scheduler?.cancelTask(taskId);

          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'status': 'deleted',
              'id': taskId,
              'title': existing.title,
            }),
          );

        case 'get':
          final taskId = _parseId(args['id']);
          if (taskId == null) {
            return ToolCallResult.failure(call.id, 'Action "get" requires a valid "id".');
          }

          final existing = await (database.select(database.schedulerTasks)
                ..where((t) => t.id.equals(taskId)))
              .getSingleOrNull();
          if (existing == null) {
            return ToolCallResult.failure(call.id, 'Task with id $taskId not found.');
          }

          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'task': _taskRowToMap(existing),
            }),
          );

        case 'list':
          final statusFilter = (args['status_filter'] as String?)?.trim().toLowerCase();
          final limit = (args['limit'] as int?) ?? 20;
          final offset = (args['offset'] as int?) ?? 0;

          var query = database.select(database.schedulerTasks)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(limit, offset: offset);

          if (statusFilter != null && statusFilter.isNotEmpty) {
            query = query..where((t) => t.status.equals(statusFilter));
          }

          final rows = await query.get();
          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'count': rows.length,
              'offset': offset,
              'limit': limit,
              'tasks': rows.map(_taskRowToMap).toList(),
            }),
          );

        case 'logs':
          final taskId = _parseId(args['id']);
          if (taskId == null) {
            return ToolCallResult.failure(call.id, 'Action "logs" requires a valid "id".');
          }

          final limit = (args['limit'] as int?) ?? 20;
          final offset = (args['offset'] as int?) ?? 0;

          final logsQuery = database.select(database.schedulerTaskLogs)
            ..where((l) => l.schedulerTaskId.equals(taskId))
            ..orderBy([(l) => OrderingTerm.desc(l.scheduledFor)])
            ..limit(limit, offset: offset);

          final logRows = await logsQuery.get();

          return ToolCallResult(
            id: call.id,
            ok: true,
            output: jsonEncode({
              'task_id': taskId,
              'count': logRows.length,
              'offset': offset,
              'limit': limit,
              'logs': logRows.map(_logRowToMap).toList(),
            }),
          );

        default:
          return ToolCallResult.failure(
            call.id,
            'Unknown action: "$action". Expected one of: "create", "edit", "delete", "get", "list", "logs".',
          );
      }
    },
  );
}

int? _parseId(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

int? _parseTimestampMillis(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is String) {
    final asInt = int.tryParse(raw.trim());
    if (asInt != null) return asInt;
    final asDate = DateTime.tryParse(raw.trim());
    if (asDate != null) return asDate.millisecondsSinceEpoch;
  }
  return null;
}

Map<String, dynamic> _taskRowToMap(SchedulerTaskRow row) {
  Map<String, dynamic> payload;
  try {
    payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
  } catch (_) {
    payload = {'raw': row.payloadJson};
  }

  return {
    'id': row.id,
    'title': row.title,
    'type': row.type,
    'status': row.status,
    'payload': payload,
    'starts_at': row.startsAt,
    'next_run_at': row.nextRunAt,
    'repeat_after': row.repeatAfter,
    'timezone': row.timezone,
    'notify': row.notify,
    'last_run_at': row.lastRunAt,
    'total_runs': row.totalRuns,
    'failures': row.failures,
    'retries_per_turn': row.retriesPerTurn,
    'created_at': row.createdAt,
    'updated_at': row.updatedAt,
  };
}

Map<String, dynamic> _logRowToMap(SchedulerTaskLogRow row) {
  return {
    'id': row.id,
    'scheduler_task_id': row.schedulerTaskId,
    'scheduled_for': row.scheduledFor,
    'started_at': row.startedAt,
    'finished_at': row.finishedAt,
    'status': row.status,
    'no_attempts': row.noAttempts,
    'error_message': row.errorMessage,
    'output_file_path': row.outputFilePath,
    'summary': row.summary,
    'notification_sent': row.notificationSent == 1,
    'notification_seen': row.notificationSeen == 1,
    'created_at': row.createdAt,
    'updated_at': row.updatedAt,
  };
}
