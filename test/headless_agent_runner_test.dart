import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:errand/agent/agent_loop.dart';
import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/services/browser_service.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/location_service.dart';
import 'package:errand/services/memory_service.dart';
import 'package:errand/services/notification_service.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:flutter_test/flutter_test.dart';

class MockLlmClient extends LlmClient {
  final List<List<Map<String, dynamic>>> receivedMessages = [];
  FutureOr<LlmMessage> Function(List<Map<String, dynamic>> messages)? onChat;

  MockLlmClient()
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'mock-key',
            model: 'mock-model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    receivedMessages.add(List<Map<String, dynamic>>.from(messages));
    if (onChat != null) {
      return await onChat!(messages);
    }
    return const LlmMessage(content: 'Task completed successfully with all findings.');
  }

  @override
  Future<LlmMessage> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    required void Function(String delta) onTextDelta,
    void Function()? onReasoningDelta,
    void Function()? onReset,
    void Function(int attempt, String reason)? onRetry,
    CancelToken? cancelToken,
  }) async {
    // Headless turns stream with a discard sink; mirror the chat behavior.
    final result = await chat(messages: messages, tools: tools, cancelToken: cancelToken);
    if (result.content != null && result.content!.isNotEmpty) {
      onTextDelta(result.content!);
    }
    return result;
  }
}

class MockNotificationService extends NotificationService {
  final List<Map<String, dynamic>> notifications = [];

  @override
  Future<bool> showNotification({
    required int id,
    required String title,
    required String body,
    String channelId = 'scheduled_tasks',
    String channelName = 'Scheduled Tasks',
    bool? isSuccess,
  }) async {
    notifications.add({
      'id': id,
      'title': title,
      'body': body,
      'isSuccess': isSuccess,
    });
    return true;
  }
}


/// AgentRunner whose headless turn blocks until the test releases it,
/// simulating a long run during which delete/cancel can land mid-flight.
class _BlockingRunner extends AgentRunner {
  final Completer<void> started;
  final Completer<void> proceed;

  _BlockingRunner({
    required super.llm,
    required super.workingDirectory,
    required super.selectedModel,
    required this.started,
    required this.proceed,
  });

  @override
  Future<HeadlessRunResult> runHeadless({
    required int taskId,
    required String prompt,
    String? taskTitle,
    Directory? scratchDirectory,
    MemoryService? memoryService,
    BrowserService? browserService,
    LocationService? locationService,
    ErrandDatabase? db,
    TaskSchedulerService? schedulerService,
    CancelToken? cancelToken,
    AgentObserver? onEvent,
    AgentTextObserver? onTextDelta,
    AgentReasoningObserver? onReasoningDelta,
    void Function()? onReset,
    AgentRetryObserver? onRetry,
  }) async {
    started.complete();
    await proceed.future;
    return const HeadlessRunResult(ok: true, output: 'done');
  }
}

void main() {
  group('Slice 4: Headless AgentRunner Integration', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late Directory scratchDir;
    late ErrandDatabase db;
    late MockNotificationService mockNotifications;
    late MockLlmClient mockLlm;
    late WorkingDirectory workingDirectory;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_headless_runner_test_');
      workspaceDir = Directory('${tempDir.path}/workspace');
      scratchDir = Directory('${tempDir.path}/workspace/.scratch');
      await workspaceDir.create(recursive: true);
      await scratchDir.create(recursive: true);

      db = ErrandDatabase.inMemory();
      mockNotifications = MockNotificationService();
      mockLlm = MockLlmClient();
      workingDirectory = WorkingDirectory(workspaceDir);
    });

    tearDown(() async {
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('runHeadless saves report via save_report tool call', () async {
      var calls = 0;
      mockLlm.onChat = (_) {
        calls++;
        if (calls == 1) {
          return const LlmMessage(
            content: '',
            toolCalls: [
              ToolCall(
                id: 'call-1',
                name: 'save_report',
                arguments: {
                  'content': '# Disk Check\nStatus: OK',
                  'name': 'summary',
                  'type': 'md',
                },
              ),
            ],
          );
        }
        return const LlmMessage(content: 'Task completed successfully with all findings.');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final result = await runner.runHeadless(
        taskId: 10,
        prompt: 'Check system status and report disk space',
        taskTitle: 'Disk Check',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Task completed successfully'));
      expect(result.reportPath, isNotNull);

      // Verify report was written to scratch directory under task prefix
      final reportFile = File(result.reportPath!);
      expect(reportFile.existsSync(), isTrue);
      expect(reportFile.parent.path, equals(scratchDir.path));
      expect(reportFile.path, contains('task-10-'));
      expect(reportFile.path.endsWith('-summary.md'), isTrue);
      expect(await reportFile.readAsString(), contains('Status: OK'));
    });

    test('runHeadless handles LLM failure gracefully without throwing', () async {
      mockLlm.onChat = (_) {
        throw const SocketException('Network connection failed');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final result = await runner.runHeadless(
        taskId: 11,
        prompt: 'Network dependent task',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Network connection failed'));
      expect(result.output, isEmpty);
    });

    test('TaskSchedulerService.executeTask completes one-off task and sends notification', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      // Insert one-off task in DB
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Daily Water Reminder',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: jsonEncode({'prompt': 'Time to drink water!'}),
          startsAt: nowMillis,
          nextRunAt: Value(nowMillis),
          notify: const Value(true),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      mockLlm.onChat = (_) {
        File('${scratchDir.path}/task-$taskId.md').writeAsStringSync('Water reminder report');
        return const LlmMessage(content: 'Task completed successfully: water reminder sent.');
      };

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isTrue);

      // Verify task row updated to completed
      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      expect(taskRow.status, equals('completed'));
      expect(taskRow.nextRunAt, isNull);
      expect(taskRow.totalRuns, equals(1));
      expect(taskRow.failures, equals(0));

      // Verify log row created and updated
      final logs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logs.length, equals(1));
      final log = logs.first;
      expect(log.status, equals('success'));
      expect(log.finishedAt, isNotNull);
      expect(log.outputFilePath, isNotNull);
      expect(log.notificationSent, equals(1));

      // Verify notification dispatched
      expect(mockNotifications.notifications.length, equals(1));
      final notif = mockNotifications.notifications.first;
      expect(notif['id'], equals(taskId));
      expect(notif['title'], contains('Task Completed: Daily Water Reminder'));
      expect(notif['body'], contains('Task completed successfully'));
      expect(notif['isSuccess'], isTrue);
    });

    test('TaskSchedulerService.executeTask advances recurring task nextRunAt', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      const repeatInterval = 3600000; // 1 hour

      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Hourly Health Check',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: jsonEncode({'prompt': 'Run diagnostic checks'}),
          startsAt: nowMillis,
          nextRunAt: Value(nowMillis),
          repeatAfter: const Value(repeatInterval),
          notify: const Value(true),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isTrue);

      // Verify task row remains scheduled with nextRunAt advanced
      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      expect(taskRow.status, equals('scheduled'));
      expect(taskRow.nextRunAt, isNotNull);
      expect(taskRow.nextRunAt!, greaterThanOrEqualTo(nowMillis + repeatInterval));
      expect(taskRow.totalRuns, equals(1));
    });

    test('TaskSchedulerService.executeTask records failure and failure notification on error', () async {
      mockLlm.onChat = (_) => throw const SocketException('Server unreachable');

      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Failing Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: jsonEncode({'prompt': 'Try to run'}),
          startsAt: nowMillis,
          notify: const Value(true),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isFalse);

      // Verify task row status failed
      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      expect(taskRow.status, equals('failed'));
      expect(taskRow.failures, equals(1));

      // Verify log row marked failed
      final logs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logs.first.status, equals('failed'));
      expect(logs.first.errorMessage, contains('Server unreachable'));

      // Verify failure notification dispatched
      expect(mockNotifications.notifications.length, equals(1));
      expect(mockNotifications.notifications.first['title'], contains('Task Failed: Failing Task'));
      expect(mockNotifications.notifications.first['isSuccess'], isFalse);
    });

    test('executeTask rejects non-allowlisted tasks (paused, cancelled, completed, running)', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;

      for (final status in ['paused', 'cancelled', 'completed', 'running']) {
        final taskId = await db.into(db.schedulerTasks).insert(
          SchedulerTasksCompanion.insert(
            title: 'Task with status $status',
            type: 'one_off',
            status: status,
            payloadJson: '{}',
            startsAt: nowMillis,
            timezone: 'UTC',
            createdAt: nowMillis,
            updatedAt: nowMillis,
          ),
        );

        final result = await scheduler.executeTask(taskId);
        expect(result, isFalse, reason: 'Should reject status $status');
      }

      // Also non-existent task
      expect(await scheduler.executeTask(99999), isFalse);
    });

    test('executeTask atomic claim prevents concurrent / double execution', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Concurrent Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      // Simulate first execution claiming and setting status to 'running'
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        const SchedulerTasksCompanion(status: Value('running')),
      );

      // Second execution attempt arrives while first is running
      final secondResult = await scheduler.executeTask(taskId);
      expect(secondResult, isFalse);
    });

    test('Recurring task failure keeps schedule alive when under retriesPerTurn', () async {
      mockLlm.onChat = (_) => throw const SocketException('Transient network error');

      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      const repeatInterval = 3600000;

      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Resilient Recurring Task',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          nextRunAt: Value(nowMillis),
          repeatAfter: const Value(repeatInterval),
          failures: const Value(0),
          retriesPerTurn: const Value(3),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isFalse);

      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      // Should remain scheduled and have nextRunAt advanced
      expect(taskRow.status, equals('scheduled'));
      expect(taskRow.failures, equals(1));
      expect(taskRow.nextRunAt, greaterThanOrEqualTo(nowMillis + repeatInterval));
    });

    test('Recurring task failure exceeding retriesPerTurn transitions to failed', () async {
      mockLlm.onChat = (_) => throw const SocketException('Persistent error');

      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Exhausted Retries Recurring Task',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          nextRunAt: Value(nowMillis),
          repeatAfter: const Value(3600000),
          failures: const Value(2), // Already failed 2 times
          retriesPerTurn: const Value(3), // 3rd failure will exceed
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isFalse);

      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      expect(taskRow.status, equals('failed'));
      expect(taskRow.failures, equals(3));
      expect(taskRow.nextRunAt, isNull);
    });

    test('Successful run resets failures counter to 0', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Recovering Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          failures: const Value(2), // Had prior failures
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isTrue);

      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
      expect(taskRow.status, equals('completed'));
      expect(taskRow.failures, equals(0)); // Reset to 0!
    });

    test('Execution timeout logs status timeout and marks run failed', () async {
      mockLlm.onChat = (_) {
        // Simulate a hanging call that delays longer than timeout
        return Future.delayed(
          const Duration(milliseconds: 200),
          () => const LlmMessage(content: 'Late response'),
        );
      };

      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Hanging Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
        timeout: const Duration(milliseconds: 50),
      );

      expect(success, isFalse);

      final logs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logs.first.status, equals('timeout'));
      expect(logs.first.errorMessage, contains('timed out'));
    });

    test('recoverStuckTasks resets abandoned running tasks', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final oldMillis = DateTime.now().millisecondsSinceEpoch - const Duration(minutes: 30).inMilliseconds;

      final recurringTaskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Stuck Recurring',
          type: 'recurring',
          status: 'running',
          payloadJson: '{}',
          startsAt: oldMillis,
          repeatAfter: const Value(3600000),
          timezone: 'UTC',
          createdAt: oldMillis,
          updatedAt: oldMillis,
        ),
      );

      final oneOffTaskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Stuck One-Off',
          type: 'one_off',
          status: 'running',
          payloadJson: '{}',
          startsAt: oldMillis,
          timezone: 'UTC',
          createdAt: oldMillis,
          updatedAt: oldMillis,
        ),
      );

      // Insert matching running logs
      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: recurringTaskId,
          scheduledFor: oldMillis,
          status: 'running',
          createdAt: oldMillis,
          updatedAt: oldMillis,
        ),
      );

      final recoveredCount = await scheduler.recoverStuckTasks(
        maxRunningDuration: const Duration(minutes: 15),
      );
      expect(recoveredCount, equals(2));

      // Recurring reset to scheduled with nextRunAt
      final recTask = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(recurringTaskId))).getSingle();
      expect(recTask.status, equals('scheduled'));
      expect(recTask.nextRunAt, isNotNull);

      // One-off marked failed
      final oneTask = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(oneOffTaskId))).getSingle();
      expect(oneTask.status, equals('failed'));

      // Running logs updated to timeout
      final logs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(recurringTaskId))).get();
      expect(logs.first.status, equals('timeout'));
    });

    test('Notification body is bounded to 250 chars', () async {
      final longSummary = 'A' * 400;
      mockLlm.onChat = (_) => LlmMessage(content: longSummary);

      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Long Report Task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: nowMillis,
          notify: const Value(true),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isTrue);
      expect(mockNotifications.notifications.length, equals(1));
      final notifBody = mockNotifications.notifications.first['body'] as String;
      expect(notifBody.length, lessThanOrEqualTo(250));
      expect(notifBody.endsWith('...'), isTrue);
    });

    test('runHeadless saves html report verbatim via save_report', () async {
      const html = '<!DOCTYPE html><html><body><p>Dashboard</p></body></html>';
      var calls = 0;
      mockLlm.onChat = (_) {
        calls++;
        if (calls == 1) {
          return const LlmMessage(
            content: '',
            toolCalls: [
              ToolCall(
                id: 'call-1',
                name: 'save_report',
                arguments: {'content': html, 'type': 'html'},
              ),
            ],
          );
        }
        return const LlmMessage(content: 'Generated HTML dashboard successfully.');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final result = await runner.runHeadless(
        taskId: 201,
        prompt: 'Generate an HTML dashboard report',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(result.ok, isTrue);
      expect(result.reportPath, isNotNull);
      expect(result.reportPath!.endsWith('.html'), isTrue);
      final file = File(result.reportPath!);
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), equals(html));
    });

    test('runHeadless last save_report call wins across turns', () async {
      var calls = 0;
      mockLlm.onChat = (_) {
        calls++;
        if (calls == 1) {
          return const LlmMessage(
            content: '',
            toolCalls: [
              ToolCall(
                id: 'call-1',
                name: 'save_report',
                arguments: {'content': '# Draft version', 'type': 'md'},
              ),
            ],
          );
        }
        if (calls == 2) {
          return const LlmMessage(
            content: '',
            toolCalls: [
              ToolCall(
                id: 'call-2',
                name: 'save_report',
                arguments: {'content': '# Final version', 'type': 'md'},
              ),
            ],
          );
        }
        return const LlmMessage(content: 'Dashboard generated');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final result = await runner.runHeadless(
        taskId: 202,
        prompt: 'Generate an HTML dashboard report',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(result.ok, isTrue);
      expect(result.reportPath, isNotNull);
      final file = File(result.reportPath!);
      expect(file.existsSync(), isTrue);
      final savedContent = await file.readAsString();
      expect(savedContent, contains('Final version'));
      expect(savedContent, isNot(contains('Draft version')));
    });

    test('runHeadless passes clean user prompt without context pollution', () async {
      String? capturedPrompt;
      mockLlm.onChat = (messages) {
        capturedPrompt = messages.last['content'] as String?;
        return const LlmMessage(content: 'Done');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      await runner.runHeadless(
        taskId: 300,
        prompt: 'Build website',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(capturedPrompt, equals('Build website'));
    });

    test('runHeadless ignores stray workspace files and falls back to final answer', () async {
      mockLlm.onChat = (_) {
        // Simulate stray file in workspace: new contract ignores it.
        File('${workspaceDir.path}/hello_world.html').writeAsStringSync('<h1>Hello World</h1>');
        return const LlmMessage(content: 'Created hello_world.html');
      };

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final result = await runner.runHeadless(
        taskId: 301,
        prompt: 'Create hello world html',
        scratchDirectory: scratchDir,
        db: db,
      );

      expect(result.ok, isTrue);
      expect(result.reportPath, contains('task-301-'));
      expect(result.reportPath!.endsWith('.md'), isTrue);
      expect(File(result.reportPath!).existsSync(), isTrue);
      expect(await File(result.reportPath!).readAsString(), contains('Created hello_world.html'));

      // Stray file is left untouched (save_report is the only blessed path).
      expect(File('${workspaceDir.path}/hello_world.html').existsSync(), isTrue);
    });

    test('recurring task execution persists edited model and provider across turns', () async {
      final scheduler = TaskSchedulerService(
        database: db,
        notificationService: mockNotifications,
      );

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: workingDirectory,
        selectedModel: 'mock-model',
      );

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final payload = jsonEncode({
        'prompt': 'Run recurring analytics',
        'model': 'google/gemini-2.5-pro',
        'providerId': 'openrouter',
      });

      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Recurring Pro Task',
          type: 'recurring',
          status: 'scheduled',
          payloadJson: payload,
          startsAt: nowMillis,
          repeatAfter: const Value(3600000), // 1 hour
          notify: const Value(false),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );

      final success = await scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: scratchDir,
      );

      expect(success, isTrue);

      // Verify that after execution and rescheduling, payloadJson retains model and providerId
      final rescheduledTask = await (db.select(db.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .getSingle();

      expect(rescheduledTask.status, equals('scheduled'));
      expect(rescheduledTask.nextRunAt, isNotNull);
      final updatedPayload = jsonDecode(rescheduledTask.payloadJson) as Map<String, dynamic>;
      expect(updatedPayload['model'], equals('google/gemini-2.5-pro'));
      expect(updatedPayload['providerId'], equals('openrouter'));
    });
  });

  group('executeTask mid-run guards', () {
    late Directory midTempDir;
    late Directory midWorkspaceDir;
    late Directory midScratchDir;
    late ErrandDatabase midDb;
    late MockNotificationService midNotifications;
    late MockLlmClient midLlm;
    late WorkingDirectory midWorkingDirectory;

    setUp(() async {
      midTempDir = await Directory.systemTemp.createTemp('errand_midrun_test_');
      midWorkspaceDir = Directory('${midTempDir.path}/workspace');
      midScratchDir = Directory('${midTempDir.path}/workspace/.scratch');
      await midWorkspaceDir.create(recursive: true);
      await midScratchDir.create(recursive: true);

      midDb = ErrandDatabase.inMemory();
      midNotifications = MockNotificationService();
      midLlm = MockLlmClient();
      midWorkingDirectory = WorkingDirectory(midWorkspaceDir);
    });

    tearDown(() async {
      await midDb.close();
      try {
        await midTempDir.delete(recursive: true);
      } catch (_) {}
    });

    Future<int> insertScheduledTask() async {
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      return midDb.into(midDb.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Mid-run task',
          type: 'one_off',
          status: 'scheduled',
          payloadJson: jsonEncode({'prompt': 'Do work'}),
          startsAt: nowMillis,
          nextRunAt: Value(nowMillis),
          notify: const Value(true),
          timezone: 'UTC',
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
    }

    TaskSchedulerService makeScheduler() => TaskSchedulerService(
          database: midDb,
          notificationService: midNotifications,
        );

    _BlockingRunner makeRunner(
      Completer<void> started,
      Completer<void> proceed,
    ) =>
        _BlockingRunner(
          llm: midLlm,
          workingDirectory: midWorkingDirectory,
          selectedModel: 'mock-model',
          started: started,
          proceed: proceed,
        );

    test('stays silent when the task is deleted mid-run (no ghost notification)',
        () async {
      final scheduler = makeScheduler();
      final started = Completer<void>();
      final proceed = Completer<void>();
      final runner = makeRunner(started, proceed);

      final taskId = await insertScheduledTask();
      final future = scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: midScratchDir,
      );
      await started.future;
      // Simulate the user deleting the task while it runs.
      expect(await scheduler.deleteTask(taskId), isTrue);
      proceed.complete();

      expect(await future, isFalse);
      expect(midNotifications.notifications, isEmpty);
      final gone = await (midDb.select(midDb.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .getSingleOrNull();
      expect(gone, isNull);
    });

    test('honors cancel written by another isolate instead of overwriting',
        () async {
      final scheduler = makeScheduler();
      final started = Completer<void>();
      final proceed = Completer<void>();
      final runner = makeRunner(started, proceed);

      final taskId = await insertScheduledTask();
      final future = scheduler.executeTask(
        taskId,
        runner: runner,
        scratchDirectory: midScratchDir,
      );
      await started.future;
      // Simulate a UI cancel landing in another isolate: token unknown here,
      // only the row flips to cancelled.
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      await (midDb.update(midDb.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .write(
        SchedulerTasksCompanion(
          status: const Value('cancelled'),
          nextRunAt: const Value(null),
          updatedAt: Value(nowMillis),
        ),
      );
      proceed.complete();

      expect(await future, isFalse);
      expect(midNotifications.notifications, isEmpty);
      final task = await (midDb.select(midDb.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .getSingle();
      expect(task.status, equals('cancelled'));
    });

    test('deleteTask removes the row and reports missing ids', () async {
      final scheduler = makeScheduler();
      final taskId = await insertScheduledTask();

      expect(await scheduler.deleteTask(taskId), isTrue);
      expect(await scheduler.deleteTask(taskId), isFalse);
      final logs = await (midDb.select(midDb.schedulerTaskLogs)).get();
      expect(logs, isEmpty);
    });
  });
}
