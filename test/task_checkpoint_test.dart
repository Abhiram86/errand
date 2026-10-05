import 'dart:io';

import 'package:errand/agent/task_checkpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory scratchDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('checkpoint_test_');
    scratchDir = Directory('${tempDir.path}/.scratch');
    await scratchDir.create(recursive: true);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('saves and loads TaskCheckpoint correctly', () async {
    final checkpoint = TaskCheckpoint(
      taskId: 42,
      turn: 3,
      resumeCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      messages: [
        {'role': 'system', 'content': 'system prompt'},
        {'role': 'user', 'content': 'hello'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{"path": "a.txt"}'},
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'file content'},
      ],
      collectedReportPath: '/path/to/report.md',
      linkedFiles: ['/path/to/data.csv'],
    );

    await checkpoint.save(scratchDir);

    final loaded = await TaskCheckpoint.load(42, scratchDir);
    expect(loaded, isNotNull);
    expect(loaded!.taskId, equals(42));
    expect(loaded.turn, equals(3));
    expect(loaded.resumeCount, equals(1));
    expect(loaded.messages.length, equals(4));
    expect(loaded.collectedReportPath, equals('/path/to/report.md'));
    expect(loaded.linkedFiles, equals(['/path/to/data.csv']));
  });

  test('load returns null and deletes checkpoint when stale (> maxAge)', () async {
    final staleTime = DateTime.now().millisecondsSinceEpoch - 5 * 3600 * 1000; // 5 hours ago
    final checkpoint = TaskCheckpoint(
      taskId: 99,
      turn: 2,
      resumeCount: 0,
      updatedAt: staleTime,
      messages: [{'role': 'user', 'content': 'old'}],
    );

    await checkpoint.save(scratchDir);
    final file = TaskCheckpoint.fileFor(99, scratchDir);
    expect(file.existsSync(), isTrue);

    final loaded = await TaskCheckpoint.load(99, scratchDir, maxAge: const Duration(hours: 4));
    expect(loaded, isNull);
    expect(file.existsSync(), isFalse); // Stale file was deleted
  });

  test('delete removes checkpoint file and tmp file', () async {
    final checkpoint = TaskCheckpoint(
      taskId: 55,
      turn: 1,
      resumeCount: 0,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      messages: [],
    );

    await checkpoint.save(scratchDir);
    final file = TaskCheckpoint.fileFor(55, scratchDir);
    expect(file.existsSync(), isTrue);

    await TaskCheckpoint.delete(55, scratchDir);
    expect(file.existsSync(), isFalse);
  });

  test('load returns null for nonexistent or corrupted checkpoint', () async {
    final missing = await TaskCheckpoint.load(12345, scratchDir);
    expect(missing, isNull);

    final corruptFile = TaskCheckpoint.fileFor(88, scratchDir);
    await corruptFile.writeAsString('not a valid json {]');
    final loaded = await TaskCheckpoint.load(88, scratchDir);
    expect(loaded, isNull);
  });
}
