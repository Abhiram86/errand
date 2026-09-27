import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:errand/agent/agent_loop.dart';
import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/services/browser_service.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/location_service.dart';
import 'package:errand/services/memory_service.dart';
import 'package:errand/services/notification_service.dart';
import 'package:errand/services/speech_service.dart';
import 'package:errand/services/task_scheduler_service.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/headless/report_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class MockNotificationService extends NotificationService {
  @override
  Future<bool> showNotification({
    required int id,
    required String title,
    required String body,
    String channelId = 'scheduled_tasks',
    String channelName = 'Scheduled Tasks',
    bool? isSuccess,
  }) async => true;
}

void main() {
  late ErrandDatabase db;
  late Directory scratchDir;
  late TaskSchedulerService service;

  setUp(() async {
    db = ErrandDatabase.inMemory();
    scratchDir = await Directory.systemTemp.createTemp('p13_1_scratch_');
    service = TaskSchedulerService(
      database: db,
      notificationService: MockNotificationService(),
    );
  });

  tearDown(() async {
    await db.close();
    if (scratchDir.existsSync()) {
      scratchDir.deleteSync(recursive: true);
    }
  });

  group('P13.1 Report paths & normalization', () {
    test('toScratchRelative converts absolute scratch path to relative', () {
      final absPath = p.join(scratchDir.path, 'task-1-1000.md');
      final rel = TaskSchedulerService.toScratchRelative(absPath, scratchDir);
      expect(rel, equals('task-1-1000.md'));
    });

    test('toScratchRelative preserves already relative path', () {
      final rel = TaskSchedulerService.toScratchRelative('task-1-1000.md', scratchDir);
      expect(rel, equals('task-1-1000.md'));
    });

    test('toScratchRelative converts legacy absolute path with scratch segment', () {
      final legacyPath = '/data/user/0/com.errand.legacy/cache/scratch/sub/task-1-1000.md';
      final rel = TaskSchedulerService.toScratchRelative(legacyPath, scratchDir);
      expect(rel, equals(p.join('sub', 'task-1-1000.md')));
    });

    test('resolveReportPath resolves relative path against scratchDir', () {
      final resolved = TaskSchedulerService.resolveReportPath('task-1-1000.md', scratchDir);
      expect(resolved, equals(p.join(scratchDir.path, 'task-1-1000.md')));
    });

    test('resolveReportPath re-anchors rotted legacy absolute path', () {
      final rottedPath = '/non/existent/path/scratch/task-1-1000.md';
      final resolved = TaskSchedulerService.resolveReportPath(rottedPath, scratchDir);
      expect(resolved, equals(p.join(scratchDir.path, 'task-1-1000.md')));
    });

    test('resolveReportPath returns existing absolute path directly', () {
      final existingFile = File(p.join(scratchDir.path, 'existing.md'))..writeAsStringSync('hi');
      final resolved = TaskSchedulerService.resolveReportPath(existingFile.path, scratchDir);
      expect(resolved, equals(existingFile.path));
    });
  });

  group('P13.1 linked_files round-trip & parsing', () {
    test('parseLinkedFiles parses JSON array safely', () {
      expect(TaskSchedulerService.parseLinkedFiles(null), isEmpty);
      expect(TaskSchedulerService.parseLinkedFiles(''), isEmpty);
      expect(TaskSchedulerService.parseLinkedFiles('invalid json'), isEmpty);
      expect(
        TaskSchedulerService.parseLinkedFiles('["data.csv", "chart.png"]'),
        equals(['data.csv', 'chart.png']),
      );
    });

    test('HeadlessReportCollector and saveReportTool collect linked_files', () async {
      final collector = HeadlessReportCollector();
      final tool = saveReportTool(
        scratchDir: scratchDir,
        taskId: 42,
        startedAtMillis: 1000,
        collector: collector,
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'call-1',
          name: 'save_report',
          arguments: {
            'content': '# Report\nDone.',
            'name': 'summary',
            'linked_files': ['aux1.csv', 'aux2.png'],
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(collector.reportPath, isNotNull);
      expect(collector.linkedFiles, equals(['aux1.csv', 'aux2.png']));
    });
  });

  group('P13.1 deleteTask hook & informed prompt file stats', () {
    test('deleteTask with deleteFiles: true removes owned report and linked files', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Cleanup Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Create physical files in scratch
      final reportFile = File(p.join(scratchDir.path, 'task-$taskId-report.md'))..writeAsStringSync('report');
      final linkedFile = File(p.join(scratchDir.path, 'task-$taskId-data.csv'))..writeAsStringSync('1,2,3');

      // Insert log row
      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-report.md'),
          linkedFiles: Value(jsonEncode(['task-$taskId-data.csv'])),
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Verify file stats
      final stats = await service.getTaskFileStats(taskId, scratchDir);
      expect(stats.count, equals(2));
      expect(stats.bytes, greaterThan(0));

      // Delete with deleteFiles: true
      final deleted = await service.deleteTask(taskId, deleteFiles: true, scratchDir: scratchDir);
      expect(deleted, isTrue);

      // Verify task row is gone
      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingleOrNull();
      expect(taskRow, isNull);

      // Verify files on disk are removed
      expect(reportFile.existsSync(), isFalse);
      expect(linkedFile.existsSync(), isFalse);
    });

    test('deleteTask with deleteFiles: false preserves files on disk', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Preserve Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final reportFile = File(p.join(scratchDir.path, 'task-$taskId-report.md'))..writeAsStringSync('report');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-report.md'),
          createdAt: now,
          updatedAt: now,
        ),
      );

      final deleted = await service.deleteTask(taskId, deleteFiles: false, scratchDir: scratchDir);
      expect(deleted, isTrue);

      // File remains on disk
      expect(reportFile.existsSync(), isTrue);
    });
  });

  group('P13.1 Orphan sweep', () {
    test('getOrphanedFiles and sweepOrphanFiles correctly identifies and deletes unreferenced files', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Active Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Owned files
      final ownedReport = File(p.join(scratchDir.path, 'task-$taskId-run.md'))..writeAsStringSync('owned');
      final ownedLinked = File(p.join(scratchDir.path, 'task-$taskId-aux.json'))..writeAsStringSync('{}');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-run.md'),
          linkedFiles: Value(jsonEncode(['task-$taskId-aux.json'])),
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Orphaned files (unreferenced)
      final orphan1 = File(p.join(scratchDir.path, 'crashed_temp_output.txt'))..writeAsStringSync('lost data');
      final orphan2 = File(p.join(scratchDir.path, 'stray_file.csv'))..writeAsStringSync('a,b,c');

      final orphans = await service.getOrphanedFiles(scratchDir);
      final orphanPaths = orphans.map((f) => p.basename(f.path)).toSet();

      expect(orphanPaths, containsAll(['crashed_temp_output.txt', 'stray_file.csv']));
      expect(orphanPaths, isNot(contains('task-$taskId-run.md')));
      expect(orphanPaths, isNot(contains('task-$taskId-aux.json')));

      // Sweep orphans
      final sweepResult = await service.sweepOrphanFiles(scratchDir);
      expect(sweepResult.count, equals(2));
      expect(sweepResult.bytes, greaterThan(0));

      // Owned files intact, orphans deleted
      expect(ownedReport.existsSync(), isTrue);
      expect(ownedLinked.existsSync(), isTrue);
      expect(orphan1.existsSync(), isFalse);
      expect(orphan2.existsSync(), isFalse);
    });

    test('keep-newest-10 prunes linked files with their report', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Recurring Prune Task',
          type: 'recurring',
          repeatAfter: const Value(60000),
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final reportFiles = <File>[];
      final linkedFiles = <File>[];

      final runner = MockRunner((runNum) {
        final r = File(p.join(scratchDir.path, 'task-$taskId-run$runNum.md'))..writeAsStringSync('run $runNum report');
        final l = File(p.join(scratchDir.path, 'task-$taskId-data$runNum.csv'))..writeAsStringSync('run $runNum data');
        reportFiles.add(r);
        linkedFiles.add(l);
        return HeadlessRunResult(
          ok: true,
          output: 'Run $runNum success',
          reportPath: r.path,
          linkedFiles: [l.path],
        );
      });

      // Execute 12 runs
      for (int i = 1; i <= 12; i++) {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
          const SchedulerTasksCompanion(status: Value('scheduled')),
        );
        await service.executeTask(
          taskId,
          runner: runner,
          scratchDirectory: scratchDir,
        );
      }

      // The first 2 runs (run 1 and run 2) should have been pruned
      expect(reportFiles[0].existsSync(), isFalse);
      expect(linkedFiles[0].existsSync(), isFalse);
      expect(reportFiles[1].existsSync(), isFalse);
      expect(linkedFiles[1].existsSync(), isFalse);

      // The newest 10 runs (runs 3 to 12, indices 2..11) should still exist
      for (int i = 2; i < 12; i++) {
        expect(reportFiles[i].existsSync(), isTrue);
        expect(linkedFiles[i].existsSync(), isTrue);
      }

      // Delete task with deleteFiles: true
      await service.deleteTask(taskId, deleteFiles: true, scratchDir: scratchDir);
      for (int i = 0; i < 12; i++) {
        expect(reportFiles[i].existsSync(), isFalse);
        expect(linkedFiles[i].existsSync(), isFalse);
      }
    });
  });

  group('Speech phrase deduplication', () {
    test('cleanSpeechPhrases deduplicates repeated and prefix phrases', () {
      expect(cleanSpeechPhrases([]), equals(''));
      expect(cleanSpeechPhrases(['hello', 'hello']), equals('hello'));
      expect(
        cleanSpeechPhrases(['what is the weather', 'what is the weather today']),
        equals('what is the weather today'),
      );
      expect(
        cleanSpeechPhrases(['hello world', 'and how are you']),
        equals('hello world and how are you'),
      );
    });
  });
}

class MockLlmClient extends LlmClient {
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
    return const LlmMessage(content: 'Success');
  }

  @override
  Future<LlmMessage> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    required void Function(String textDelta) onTextDelta,
    void Function()? onReasoningDelta,
    void Function()? onReset,
    void Function(int attempt, String reason)? onRetry,
    CancelToken? cancelToken,
  }) async {
    return const LlmMessage(content: 'Success');
  }
}

class MockRunner extends AgentRunner {
  final HeadlessRunResult Function(int runCount) onRun;
  int runs = 0;

  MockRunner(this.onRun, [Directory? scratchDir])
      : super(
          llm: MockLlmClient(),
          workingDirectory: WorkingDirectory(scratchDir ?? Directory.systemTemp),
          selectedModel: 'mock-model',
        );

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
    runs++;
    return onRun(runs);
  }
}

