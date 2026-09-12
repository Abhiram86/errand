import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/legacy_workspace_tool.dart';

void main() {
  group('fileTools metadata and sorting', () {
    late Directory tempDir;
    late WorkingDirectory workspace;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_meta_test_');
      workspace = WorkingDirectory(tempDir);

      // Create files with deliberate sizes and timestamps.
      final smallFile = File('${tempDir.path}/small.txt');
      await smallFile.writeAsString('hello'); // 5 bytes

      final mediumFile = File('${tempDir.path}/medium.dat');
      // Write 2048 bytes (2 KB)
      await mediumFile.writeAsBytes(List.filled(2048, 65));

      final bigFile = File('${tempDir.path}/big.bin');
      // Write 1048576 bytes (1 MB)
      await bigFile.writeAsBytes(List.filled(1048576, 66));

      final subDir = Directory('${tempDir.path}/sub');
      await subDir.create();
      final nested = File('${tempDir.path}/sub/nested.txt');
      await nested.writeAsString('nested data');

      // Adjust last modified timestamps
      // small.txt: 3 days ago
      await smallFile.setLastModified(DateTime.now().subtract(const Duration(days: 3)));
      // medium.dat: 1 day ago
      await mediumFile.setLastModified(DateTime.now().subtract(const Duration(days: 1)));
      // big.bin: 5 minutes ago (newest)
      await bigFile.setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('listTool outputs metadata columns by default', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_1',
          name: 'list',
          arguments: {'path': '.'},
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('T        SIZE          MODIFIED  NAME'));
      expect(res.output, contains('small.txt'));
      expect(res.output, contains('medium.dat'));
      expect(res.output, contains('big.bin'));
      expect(res.output, contains('sub'));
      expect(res.output, contains('  MB'));
      expect(res.output, contains('  KB'));
    });

    test('listTool outputs plain paths when metadata is false', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_2',
          name: 'list',
          arguments: {
            'path': '.',
            'metadata': false,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, isNot(contains('T        SIZE          MODIFIED  NAME')));
      expect(res.output, isNot(contains('  MB')));
      expect(res.output, contains('small.txt'));
      expect(res.output, contains('medium.dat'));
    });

    test('listTool sorts by size descending', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_size_desc',
          name: 'list',
          arguments: {
            'path': '.',
            'sort_by': 'size',
            'sort_order': 'desc',
          },
        ),
      );

      expect(res.ok, isTrue);
      final lines = res.output.split('\n');
      final entryLines = lines.where((l) => l.contains('.txt') || l.contains('.dat') || l.contains('.bin')).toList();
      // big.bin (1 MB) should be before medium.dat (2 KB), which is before small.txt (5 B)
      final bigIdx = entryLines.indexWhere((l) => l.contains('big.bin'));
      final medIdx = entryLines.indexWhere((l) => l.contains('medium.dat'));
      final smallIdx = entryLines.indexWhere((l) => l.contains('small.txt'));

      expect(bigIdx < medIdx, isTrue);
      expect(medIdx < smallIdx, isTrue);
    });

    test('listTool sorts by modified timestamp descending by default when sort_by=modified', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_mod_desc',
          name: 'list',
          arguments: {
            'path': '.',
            'sort_by': 'modified',
          },
        ),
      );

      expect(res.ok, isTrue);
      final lines = res.output.split('\n');
      final entryLines = lines.where((l) => l.contains('.txt') || l.contains('.dat') || l.contains('.bin')).toList();
      // big.bin (5 min ago) is newest, then medium.dat (1 day ago), then small.txt (3 days ago)
      final bigIdx = entryLines.indexWhere((l) => l.contains('big.bin'));
      final medIdx = entryLines.indexWhere((l) => l.contains('medium.dat'));
      final smallIdx = entryLines.indexWhere((l) => l.contains('small.txt'));

      expect(bigIdx < medIdx, isTrue);
      expect(medIdx < smallIdx, isTrue);
    });

    test('listTool filters entries by grep on size unit', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_grep_mb',
          name: 'list',
          arguments: {
            'path': '.',
            'grep': 'MB',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('big.bin'));
      expect(res.output, isNot(contains('small.txt')));
      expect(res.output, isNot(contains('medium.dat')));
    });

    test('listTool filters entries by grep on directory type (^d)', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_grep_dir',
          name: 'list',
          arguments: {
            'path': '.',
            'grep': '^d',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('sub'));
      expect(res.output, isNot(contains('small.txt')));
      expect(res.output, isNot(contains('big.bin')));
    });

    test('findTool returns metadata and supports sorting by size', () async {
      final tool = findTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'find_1',
          name: 'find',
          arguments: {
            'path': '.',
            'pattern': '*',
            'sort_by': 'size',
            'sort_order': 'desc',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('T        SIZE          MODIFIED  NAME'));
      expect(res.output, contains('nested.txt'));
      expect(res.output, contains('big.bin'));
    });

    test('legacy workspace router forwards sort_by and metadata correctly', () async {
      final router = legacyWorkspaceTool(workspace);
      final res = await router.handler(
        const ToolCall(
          id: 'ws_list',
          name: 'workspace',
          arguments: {
            'action': 'list',
            'path': '.',
            'sort_by': 'size',
            'sort_order': 'desc',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('T        SIZE          MODIFIED  NAME'));
      expect(res.output, contains('big.bin'));
    });
  });
}
