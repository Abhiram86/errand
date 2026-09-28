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
      File(p.join(scratchDir.path, 'aux1.csv')).writeAsStringSync('col1,col2\n1,2');
      File(p.join(scratchDir.path, 'aux2.png')).writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);

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

    test('deleteTask with workspace linked files, scratch copies, and file:// URIs removes both scratch and workspace files', () async {
      final workspaceDir = Directory.systemTemp.createTempSync('p13_1_workspace_');
      addTearDown(() {
        if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Workspace Linked Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Create report file in scratch
      final reportFile = File(p.join(scratchDir.path, 'task-$taskId-report.md'))..writeAsStringSync('report');
      // Create scratch copy of linked file
      final scratchCopy = File(p.join(scratchDir.path, 'task-$taskId-1000-link-data.csv'))..writeAsStringSync('1,2,3');
      // Create original linked file in workspace
      final wsFile = File(p.join(workspaceDir.path, 'data.csv'))..writeAsStringSync('1,2,3');
      // Create another file referenced via file:// URI in workspace
      final wsUriFile = File(p.join(workspaceDir.path, 'output.txt'))..writeAsStringSync('out');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-report.md'),
          linkedFiles: Value(jsonEncode([
            'task-$taskId-1000-link-data.csv',
            'file://${wsUriFile.path}',
          ])),
          createdAt: now,
          updatedAt: now,
        ),
      );

      final files = await service.getOwnedFilesForTask(taskId, scratchDir, workspaceDir);
      final filePaths = files.map((f) => f.path).toSet();
      expect(filePaths, contains(reportFile.path));
      expect(filePaths, contains(scratchCopy.path));
      expect(filePaths, contains(wsFile.path));
      expect(filePaths, contains(wsUriFile.path));

      final deleted = await service.deleteTask(
        taskId,
        deleteFiles: true,
        scratchDir: scratchDir,
        workspaceDir: workspaceDir,
      );
      expect(deleted, isTrue);

      expect(reportFile.existsSync(), isFalse);
      expect(scratchCopy.existsSync(), isFalse);
      expect(wsFile.existsSync(), isFalse);
      expect(wsUriFile.existsSync(), isFalse);
    });

    test('deleteLogsForTask clears log rows and removes owned files when deleteFiles is true', () async {
      final workspaceDir = Directory.systemTemp.createTempSync('p13_1_workspace_logs_');
      addTearDown(() {
        if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Logs Clear Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final reportFile = File(p.join(scratchDir.path, 'task-$taskId-rep.md'))..writeAsStringSync('rep');
      final wsFile = File(p.join(workspaceDir.path, 'table.csv'))..writeAsStringSync('col1,col2');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-rep.md'),
          linkedFiles: Value(jsonEncode([wsFile.path])),
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Verify log row exists
      final logRowsBefore = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logRowsBefore, hasLength(1));

      // Clear logs with deleteFiles: true
      final deletedCount = await service.deleteLogsForTask(
        taskId,
        deleteFiles: true,
        scratchDir: scratchDir,
        workspaceDir: workspaceDir,
      );
      expect(deletedCount, equals(1));

      // Task row remains intact
      final taskRow = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingleOrNull();
      expect(taskRow, isNotNull);

      // Logs are deleted from DB
      final logRowsAfter = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logRowsAfter, isEmpty);

      // Files are deleted from disk
      expect(reportFile.existsSync(), isFalse);
      expect(wsFile.existsSync(), isFalse);
    });

    test('deleteLogsForTask clears log rows but preserves files when deleteFiles is false', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Preserve Logs Files Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final reportFile = File(p.join(scratchDir.path, 'task-$taskId-preserve.md'))..writeAsStringSync('preserve');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value('task-$taskId-preserve.md'),
          createdAt: now,
          updatedAt: now,
        ),
      );

      final deletedCount = await service.deleteLogsForTask(taskId, deleteFiles: false, scratchDir: scratchDir);
      expect(deletedCount, equals(1));

      // Logs are gone
      final logRowsAfter = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
      expect(logRowsAfter, isEmpty);

      // File preserved
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

  group('P13.1 deletion containment & failure-proof pruning', () {
    test('isScratchOwned accepts inside files, rejects outside and traversal', () {
      expect(
        TaskSchedulerService.isScratchOwned(
          p.join(scratchDir.path, 'task-1-a.md'),
          scratchDir,
        ),
        isTrue,
      );
      expect(
        TaskSchedulerService.isScratchOwned(
          p.join(scratchDir.path, 'sub', 'dir', 'b.md'),
          scratchDir,
        ),
        isTrue,
      );
      final sibling = Directory(p.join(scratchDir.parent.path, 'p13_1_sibling_${DateTime.now().millisecondsSinceEpoch}'));
      try {
        expect(
          TaskSchedulerService.isScratchOwned(
            p.join(sibling.path, 'evil.md'),
            scratchDir,
          ),
          isFalse,
        );
        expect(
          TaskSchedulerService.isScratchOwned(
            p.join(scratchDir.path, '..', p.basename(sibling.path), 'evil.md'),
            scratchDir,
          ),
          isFalse,
        );
      } finally {
        if (sibling.existsSync()) sibling.deleteSync(recursive: true);
      }
    });

    test('getOwnedFilesForTask and deleteTask never touch files outside scratch', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Rotted Path Task',
          type: 'one_off',
          status: 'completed',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // A legacy absolute row pointing outside scratch (e.g. user file).
      final outsideDir = await Directory.systemTemp.createTemp('p13_1_outside_');
      final outsideFile = File(p.join(outsideDir.path, 'precious.md'))
        ..writeAsStringSync('do not delete');
      // A traversal-style stored rel escaping scratch.
      final siblingDir = await Directory.systemTemp.createTemp('p13_1_sib_');
      final siblingFile = File(p.join(siblingDir.path, 'sib.md'))
        ..writeAsStringSync('do not delete');

      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now,
          status: 'success',
          outputFilePath: Value(outsideFile.path),
          linkedFiles: Value(jsonEncode([
            p.join('..', p.basename(siblingDir.path), 'sib.md'),
          ])),
          createdAt: now,
          updatedAt: now,
        ),
      );

      final owned = await service.getOwnedFilesForTask(taskId, scratchDir);
      expect(owned, isEmpty);

      final deleted = await service.deleteTask(taskId, deleteFiles: true, scratchDir: scratchDir);
      expect(deleted, isTrue);
      expect(outsideFile.existsSync(), isTrue);
      expect(siblingFile.existsSync(), isTrue);

      outsideDir.deleteSync(recursive: true);
      siblingDir.deleteSync(recursive: true);
    });

    test('consecutive failures do not evict older good reports from keep-10', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.into(db.schedulerTasks).insert(
        SchedulerTasksCompanion.insert(
          title: 'Flaky Recurring Task',
          type: 'recurring',
          repeatAfter: const Value(60000),
          retriesPerTurn: const Value(100),
          status: 'scheduled',
          payloadJson: '{}',
          startsAt: now,
          timezone: 'UTC',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final goodReports = <File>[];
      final runner = MockRunner((runNum) {
        if (runNum <= 2) {
          final r = File(p.join(scratchDir.path, 'task-$taskId-good$runNum.md'))
            ..writeAsStringSync('good $runNum');
          goodReports.add(r);
          return HeadlessRunResult(
            ok: true,
            output: 'Run $runNum success',
            reportPath: r.path,
          );
        }
        return const HeadlessRunResult(
          ok: false,
          output: 'Run failed',
          errorMessage: 'SocketException: network is unreachable',
        );
      });

      for (int i = 1; i <= 14; i++) {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
          const SchedulerTasksCompanion(status: Value('scheduled')),
        );
        await service.executeTask(
          taskId,
          runner: runner,
          scratchDirectory: scratchDir,
        );
      }

      // Failure rows carry no files, so both good reports survive pruning.
      expect(goodReports[0].existsSync(), isTrue);
      expect(goodReports[1].existsSync(), isTrue);
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

    test('SpeechService.cleanSpeechText deduplicates repeated sentences, words, and punctuation variations', () {
      expect(SpeechService.cleanSpeechText(''), equals(''));
      expect(SpeechService.cleanSpeechText('hello hello'), equals('hello'));
      expect(SpeechService.cleanSpeechText('hello world hello world'), equals('hello world'));
      expect(SpeechService.cleanSpeechText('Hello world. Hello world'), equals('Hello world.'));
      expect(SpeechService.cleanSpeechText('Hello world. Hello world.'), equals('Hello world.'));
      expect(SpeechService.cleanSpeechText('What is the weather today? What is the weather today?'), equals('What is the weather today?'));
      expect(SpeechService.cleanSpeechText('what is the weather today. What is the weather today'), equals('what is the weather today.'));
      expect(SpeechService.cleanSpeechText('turn on the light turn on the light'), equals('turn on the light'));
      expect(SpeechService.cleanSpeechText('hellohello'), equals('hello'));
      expect(
        SpeechService.cleanSpeechText('This is a normal message that is not duplicated.'),
        equals('This is a normal message that is not duplicated.'),
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

