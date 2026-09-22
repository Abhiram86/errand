import 'dart:io';

import 'package:errand/agent/system_prompt.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/memory_service.dart';
import 'package:errand/tools/headless/report_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Slice 3: Headless System Prompt', () {
    late Directory tempDir;
    late Directory currentDir;
    late Directory scratchDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_prompt_test_');
      currentDir = Directory('${tempDir.path}/workspace');
      scratchDir = Directory('${tempDir.path}/workspace/.scratch');
      await currentDir.create(recursive: true);
      await scratchDir.create(recursive: true);
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('generates expected background headless instructions', () {
      final prompt = headlessSystemPromptFor(
        currentDir: currentDir,
        scratchDir: scratchDir,
        taskId: 42,
        taskTitle: 'Hourly Weather Check',
        locationSummary: 'San Francisco, CA',
        isDebug: false,
      );

      // Autonomous persona
      expect(prompt, contains('running autonomously in the background as a headless scheduled task'));
      expect(prompt, contains('NO active foreground UI or live interactive user present'));

      // Context injection
      expect(prompt, contains('Current Task ID: 42 ("Hourly Weather Check")'));
      expect(prompt, contains('Current working directory: ${currentDir.path}'));
      expect(prompt, contains('Scratch directory: ${scratchDir.path}'));
      expect(prompt, contains('Current user location: San Francisco, CA'));

      // Output & Scratch policy
      expect(prompt, contains('call the `save_report` tool ONCE'));
      expect(prompt, contains('Never write report files via bash'));
      expect(prompt, contains('task-42-'));
      expect(prompt, contains('NEVER write files directly into /storage/emulated/0/ or /sdcard/'));

      // Intent policy (non-UI allowed, UI-popping prohibited)
      expect(prompt, contains('Non-UI / Background Intents (ALLOWED)'));
      expect(prompt, contains('UI-Popping Intents (PROHIBITED)'));
      expect(prompt, contains('action:"open_app"'));

      // Browser offscreen
      expect(prompt, contains('Runs completely offscreen in the background without opening UI sheets'));

      // Bash arithmetic and destructive guards
      expect(prompt, contains(r'echo $((expr))'));
      expect(prompt, contains('Destructive Operations Blocked'));

      // Schedule task rules
      expect(prompt, contains('You can only edit your own running task (matching current task id)'));
      expect(prompt, contains('Creating new tasks (create) or deleting tasks (delete) is strictly blocked'));

      // Memory rules
      expect(prompt, contains('Memory writes (create, edit) are strictly blocked in headless mode'));

      // Exclusion of interactive tools
      expect(prompt, contains('screen & screen_act & attached_files: Not available in headless mode'));
      expect(prompt, isNot(contains('Screen & Device Capabilities (ENABLED)')));
      expect(prompt, isNot(contains('Screen & Device Capabilities (DISABLED)')));
      expect(prompt, isNot(contains('Development & Diagnostics (DEBUG MODE)')));
    });

    test('includes debug section when isDebug is true', () {
      final prompt = headlessSystemPromptFor(
        currentDir: currentDir,
        scratchDir: scratchDir,
        taskId: 7,
        isDebug: true,
      );

      expect(prompt, contains('Development & Diagnostics (DEBUG MODE)'));
      expect(prompt, contains('Current Task ID: 7'));
    });
  });

  group('Slice 3: ToolRegistry.headless factory', () {
    late Directory tempDir;
    late Directory currentDir;
    late ErrandDatabase db;
    late MemoryService memoryService;
    late ToolRegistry registry;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_registry_test_');
      currentDir = Directory('${tempDir.path}/workspace');
      await currentDir.create(recursive: true);
      db = ErrandDatabase.inMemory();
      memoryService = MemoryService(db: db);

      registry = ToolRegistry.headless(
        currentDir: currentDir,
        currentTaskId: 101,
        db: db,
        memoryService: memoryService,
        scratchDirectory: Directory('${tempDir.path}/workspace/.scratch'),
        reportCollector: HeadlessReportCollector(),
        runStartedAtMillis: 1700000000000,
      );
    });

    tearDown(() async {
      registry.dispose();
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('registers expected headless toolset and strictly excludes UI tools', () {
      final toolNames = registry.all.map((t) => t.name).toSet();

      // Included tools
      expect(toolNames, contains('read'));
      expect(toolNames, contains('bash'));
      expect(toolNames, contains('websearch'));
      expect(toolNames, contains('webfetch'));
      expect(toolNames, contains('intent'));
      expect(toolNames, contains('location'));
      expect(toolNames, contains('memory'));
      expect(toolNames, contains('browser'));
      expect(toolNames, contains('schedule_task'));
      expect(toolNames, contains('save_report'));

      // Excluded tools
      expect(toolNames, isNot(contains('screen')));
      expect(toolNames, isNot(contains('screen_act')));
      expect(toolNames, isNot(contains('act')));
      expect(toolNames, isNot(contains('attached_files')));
    });

    test('wires bash with isHeadless: true', () async {
      final result = await registry.execute(
        const ToolCall(
          id: 'call-bash-rm',
          name: 'bash',
          arguments: {'command': 'rm -rf dangerous_dir'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, equals('headless_destructive_blocked'));
    });

    test('wires memory with isHeadless: true', () async {
      final result = await registry.execute(
        const ToolCall(
          id: 'call-mem-create',
          name: 'memory',
          arguments: {
            'action': 'create',
            'about': 'Test memory',
            'description': 'Headless attempt',
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, equals('headless_memory_write_blocked'));
    });

    test('wires schedule_task with isHeadless: true and currentTaskId', () async {
      // Create is blocked
      final createRes = await registry.execute(
        const ToolCall(
          id: 'call-sched-create',
          name: 'schedule_task',
          arguments: {
            'action': 'create',
            'title': 'Recursive task',
            'prompt': 'Do recursion',
          },
        ),
      );
      expect(createRes.ok, isFalse);
      expect(createRes.error?.type, equals('headless_recursion_blocked'));

      // Edit on different task ID (not 101) is blocked
      final editOtherRes = await registry.execute(
        const ToolCall(
          id: 'call-sched-edit-other',
          name: 'schedule_task',
          arguments: {
            'action': 'edit',
            'id': 999,
            'title': 'Hack other task',
          },
        ),
      );
      expect(editOtherRes.ok, isFalse);
      expect(editOtherRes.error?.type, equals('headless_cross_task_edit_blocked'));
      expect(editOtherRes.error?.message, contains('can only edit its own task (id: 101)'));
    });

    test('wires browser with isHeadless: true', () {
      final browser = registry.all.firstWhere((t) => t.name == 'browser');
      expect(browser.description, contains('Embedded headless web browser'));
      expect(browser.description, contains('offscreen without showing UI'));
    });

    test('wires intent with isHeadless: true and blocks UI-popping actions', () async {
      // open_app blocked
      final appRes = await registry.execute(
        const ToolCall(
          id: 'call-app',
          name: 'intent',
          arguments: {
            'action': 'open_app',
            'package': 'com.spotify.music',
          },
        ),
      );
      expect(appRes.ok, isFalse);
      expect(appRes.error?.type, equals('headless_ui_intent_blocked'));

      // settings blocked
      final settingsRes = await registry.execute(
        const ToolCall(
          id: 'call-settings',
          name: 'intent',
          arguments: {
            'action': 'settings',
            'page': 'wifi',
          },
        ),
      );
      expect(settingsRes.ok, isFalse);
      expect(settingsRes.error?.type, equals('headless_ui_intent_blocked'));

      // open_file blocked
      final fileRes = await registry.execute(
        const ToolCall(
          id: 'call-file',
          name: 'intent',
          arguments: {
            'action': 'open_file',
            'path': '/storage/emulated/0/Download/test.pdf',
          },
        ),
      );
      expect(fileRes.ok, isFalse);
      expect(fileRes.error?.type, equals('headless_ui_intent_blocked'));

      // open_url blocked
      final urlRes = await registry.execute(
        const ToolCall(
          id: 'call-url',
          name: 'intent',
          arguments: {
            'action': 'open_url',
            'url': 'https://example.com',
          },
        ),
      );
      expect(urlRes.ok, isFalse);
      expect(urlRes.error?.type, equals('headless_ui_intent_blocked'));

      // intent with android.settings.* blocked
      final customSettingsRes = await registry.execute(
        const ToolCall(
          id: 'call-custom-settings',
          name: 'intent',
          arguments: {
            'action': 'intent',
            'android_action': 'android.settings.DISPLAY_SETTINGS',
          },
        ),
      );
      expect(customSettingsRes.ok, isFalse);
      expect(customSettingsRes.error?.type, equals('headless_ui_intent_blocked'));

      // docs is allowed
      final docsRes = await registry.execute(
        const ToolCall(
          id: 'call-docs',
          name: 'intent',
          arguments: {
            'action': 'docs',
            'name': 'alarm',
          },
        ),
      );
      expect(docsRes.ok, isTrue);
    });
  });
}
