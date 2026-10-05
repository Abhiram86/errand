import 'dart:io';

import 'package:errand/agent/system_prompt.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/services/database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory currentDir;
  late ErrandDatabase db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('browser_policy_test_');
    currentDir = Directory('${tempDir.path}/workspace');
    await currentDir.create(recursive: true);
    db = ErrandDatabase.inMemory();
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('ToolRegistry.headless includes browser when enableBrowser is true', () {
    final registry = ToolRegistry.headless(
      currentDir: currentDir,
      currentTaskId: 1,
      db: db,
      enableBrowser: true,
    );
    expect(registry.all.any((t) => t.name == 'browser'), isTrue);
    registry.dispose();
  });

  test('ToolRegistry.headless excludes browser when enableBrowser is false', () {
    final registry = ToolRegistry.headless(
      currentDir: currentDir,
      currentTaskId: 1,
      db: db,
      enableBrowser: false,
    );
    expect(registry.all.any((t) => t.name == 'browser'), isFalse);
    // Other headless tools are still present
    expect(registry.all.any((t) => t.name == 'webfetch'), isTrue);
    expect(registry.all.any((t) => t.name == 'websearch'), isTrue);
    expect(registry.all.any((t) => t.name == 'bash'), isTrue);
    registry.dispose();
  });

  test('headlessSystemPromptFor omits browser instructions and promotes webfetch when enableBrowser is false', () {
    final prompt = headlessSystemPromptFor(
      currentDir: currentDir,
      scratchDir: tempDir,
      taskId: 10,
      enableBrowser: false,
    );

    expect(prompt, isNot(contains('- browser: Offscreen web automation tool group')));
    expect(prompt, contains('webfetch & websearch: Use webfetch to read web pages'));
  });

  test('headlessSystemPromptFor includes browser instructions when enableBrowser is true', () {
    final prompt = headlessSystemPromptFor(
      currentDir: currentDir,
      scratchDir: tempDir,
      taskId: 10,
      enableBrowser: true,
    );

    expect(prompt, contains('- browser: Offscreen web automation tool group'));
  });
}
