import 'dart:io';

import 'package:errand/agent/tool.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/memory_service.dart';
import 'package:errand/services/shell_service.dart';
import 'package:errand/tools/bash_tool.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/memory_tool.dart';
import 'package:errand/tools/schedule_task_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Slice 1: Headless Tool Guards', () {
    late Directory tempDir;
    late WorkingDirectory workingDirectory;
    late ErrandDatabase db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_headless_test_');
      workingDirectory = WorkingDirectory(tempDir);
      db = ErrandDatabase.inMemory();
    });

    tearDown(() async {
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    group('bashTool headless guard', () {
      test('blocks destructive command immediately in headless mode', () async {
        final tool = bashTool(
          workingDirectory: workingDirectory,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-1',
            name: 'bash',
            arguments: {
              'command': 'rm -rf foo',
            },
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.type, equals('headless_destructive_blocked'));
        expect(
          result.error?.message,
          contains('Cannot perform destructive operations in headless background mode'),
        );
      });

      test('allows safe non-destructive command in headless mode', () async {
        final tool = bashTool(
          workingDirectory: workingDirectory,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-2',
            name: 'bash',
            arguments: {
              'command': 'echo "headless safe"',
            },
          ),
        );

        expect(result.ok, isTrue);
        expect(result.output, contains('headless safe'));
      });

      test('allows destructive command in non-headless mode when confirmed', () async {
        final tool = bashTool(
          workingDirectory: workingDirectory,
          isHeadless: false,
          onConfirmCommand: ({required title, required command, reason}) async {
            return ConfirmationDecision.accept;
          },
        );

        // Target file to remove
        final testFile = File('${tempDir.path}/test_delete.txt');
        await testFile.writeAsString('delete me');

        final result = await tool.handler(
          ToolCall(
            id: 'call-3',
            name: 'bash',
            arguments: {
              'command': 'rm ${testFile.path}',
            },
          ),
        );

        expect(result.ok, isTrue);
      });
    });

    group('scheduleTaskTool headless guard', () {
      test('blocks create action in headless mode', () async {
        final tool = scheduleTaskTool(
          db: db,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-4',
            name: 'schedule_task',
            arguments: {
              'action': 'create',
              'title': 'Recursive task',
              'prompt': 'Run again',
              'schedule_type': 'one_off',
            },
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.type, equals('headless_recursion_blocked'));
        expect(
          result.error?.message,
          contains('disabled in background scheduled tasks to prevent recursive scheduling loops'),
        );
      });

      test('blocks delete action in headless mode', () async {
        final tool = scheduleTaskTool(
          db: db,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-5',
            name: 'schedule_task',
            arguments: {
              'action': 'delete',
              'id': 1,
            },
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.type, equals('headless_recursion_blocked'));
        expect(
          result.error?.message,
          contains('disabled in background scheduled tasks'),
        );
      });

      test('allows list and get in headless mode', () async {
        // Create a task using non-headless tool first
        final normalTool = scheduleTaskTool(
          db: db,
          isHeadless: false,
        );
        final createRes = await normalTool.handler(
          const ToolCall(
            id: 'c-1',
            name: 'schedule_task',
            arguments: {
              'action': 'create',
              'title': 'Existing task',
              'prompt': 'Do work',
              'schedule_type': 'one_off',
            },
          ),
        );
        expect(createRes.ok, isTrue);

        final headlessTool = scheduleTaskTool(
          db: db,
          isHeadless: true,
          currentTaskId: 1,
        );

        final listRes = await headlessTool.handler(
          const ToolCall(
            id: 'call-list',
            name: 'schedule_task',
            arguments: {'action': 'list'},
          ),
        );
        expect(listRes.ok, isTrue);

        final getRes = await headlessTool.handler(
          const ToolCall(
            id: 'call-get',
            name: 'schedule_task',
            arguments: {'action': 'get', 'id': 1},
          ),
        );
        expect(getRes.ok, isTrue);
      });

      test('allows edit on own task in headless mode, blocks editing other tasks', () async {
        final normalTool = scheduleTaskTool(db: db, isHeadless: false);
        // Create task 1 and task 2
        await normalTool.handler(
          const ToolCall(
            id: 'c-1',
            name: 'schedule_task',
            arguments: {
              'action': 'create',
              'title': 'Task One',
              'prompt': 'Prompt 1',
              'schedule_type': 'one_off',
            },
          ),
        );
        await normalTool.handler(
          const ToolCall(
            id: 'c-2',
            name: 'schedule_task',
            arguments: {
              'action': 'create',
              'title': 'Task Two',
              'prompt': 'Prompt 2',
              'schedule_type': 'one_off',
            },
          ),
        );

        // Headless tool bound to task 1
        final headlessToolTask1 = scheduleTaskTool(
          db: db,
          isHeadless: true,
          currentTaskId: 1,
        );

        // Editing task 1 (self) should succeed (including delay_seconds)
        final editSelfRes = await headlessToolTask1.handler(
          const ToolCall(
            id: 'edit-self',
            name: 'schedule_task',
            arguments: {
              'action': 'edit',
              'id': 1,
              'title': 'Task One Updated',
              'delay_seconds': 120,
            },
          ),
        );
        expect(editSelfRes.ok, isTrue);

        // Editing task 2 from task 1 runner should be blocked
        final editOtherRes = await headlessToolTask1.handler(
          const ToolCall(
            id: 'edit-other',
            name: 'schedule_task',
            arguments: {
              'action': 'edit',
              'id': 2,
              'title': 'Task Two Hacked',
            },
          ),
        );
        expect(editOtherRes.ok, isFalse);
        expect(editOtherRes.error?.type, equals('headless_cross_task_edit_blocked'));
        expect(editOtherRes.error?.message, contains('can only edit its own task (id: 1)'));

        // Headless tool with no currentTaskId should also be blocked from edit
        final headlessToolNoId = scheduleTaskTool(
          db: db,
          isHeadless: true,
          currentTaskId: null,
        );
        final editNoIdRes = await headlessToolNoId.handler(
          const ToolCall(
            id: 'edit-no-id',
            name: 'schedule_task',
            arguments: {
              'action': 'edit',
              'id': 1,
              'title': 'Attempt without context',
            },
          ),
        );
        expect(editNoIdRes.ok, isFalse);
        expect(editNoIdRes.error?.type, equals('headless_cross_task_edit_blocked'));
      });
    });

    group('memoryTool headless guard', () {
      late MemoryService memoryService;

      setUp(() {
        memoryService = MemoryService(db: db);
      });

      test('blocks create action in headless mode', () async {
        final tool = memoryTool(
          memoryService: memoryService,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-6',
            name: 'memory',
            arguments: {
              'action': 'create',
              'about': 'User preference',
              'description': 'Loves dark mode',
            },
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.type, equals('headless_memory_write_blocked'));
        expect(
          result.error?.message,
          contains('Memory cannot be modified in background headless mode'),
        );
      });

      test('blocks edit action in headless mode', () async {
        final tool = memoryTool(
          memoryService: memoryService,
          isHeadless: true,
        );

        final result = await tool.handler(
          const ToolCall(
            id: 'call-7',
            name: 'memory',
            arguments: {
              'action': 'edit',
              'id': 'mem-1',
              'about': 'Updated preference',
            },
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.type, equals('headless_memory_write_blocked'));
      });

      test('allows find and read in headless mode', () async {
        // Create memory using non-headless tool
        final normalTool = memoryTool(
          memoryService: memoryService,
          isHeadless: false,
        );
        final createRes = await normalTool.handler(
          const ToolCall(
            id: 'c-mem',
            name: 'memory',
            arguments: {
              'action': 'create',
              'about': 'Python preference',
              'description': 'Prefers pytest',
              'keywords': ['python', 'testing'],
            },
          ),
        );
        expect(createRes.ok, isTrue);

        // Query memory using headless tool
        final headlessTool = memoryTool(
          memoryService: memoryService,
          isHeadless: true,
        );

        final findRes = await headlessTool.handler(
          const ToolCall(
            id: 'call-find',
            name: 'memory',
            arguments: {
              'action': 'find',
              'query': 'python',
            },
          ),
        );
        expect(findRes.ok, isTrue);
        expect(findRes.output, contains('Python preference'));
      });
    });
  });
}
