import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/services/tool_output_file_service.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/types/tool.dart';

void main() {
  late Directory tempDir;
  late ToolOutputFileService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tool_output_test_');
    service = ToolOutputFileService(
      overrideDirectory: tempDir,
      thresholdChars: 4000,
      headChars: 1000,
      tailChars: 1000,
      ttl: const Duration(minutes: 10),
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ToolOutputFileService unit tests', () {
    test('outputs below threshold are returned inline with no file created', () async {
      final shortText = 'Small output' * 50; // ~600 chars, < 4000
      final result = await service.processOutput(
        callId: 'call_1',
        output: shortText,
      );

      expect(result, equals(shortText));
      expect(tempDir.listSync().isEmpty, isTrue);
    });

    test('outputs above threshold create a cache file and return head/tail preview', () async {
      // 10,000 chars output with header
      final header = 'Header: Section Title\n';
      final body = List.generate(500, (i) => 'Line $i: Content').join('\n');
      final largeText = '$header$body';

      expect(largeText.length, greaterThan(4000));

      final preview = await service.processOutput(
        callId: 'call_large_1',
        output: largeText,
      );

      // File was created in tempDir
      final files = tempDir.listSync().whereType<File>().toList();
      expect(files.length, equals(1));
      expect(files.first.path, contains('tool-call_large_1-output.txt'));

      // File contains the complete unabridged text
      expect(files.first.readAsStringSync(), equals(largeText));

      // Preview retains top header
      expect(preview, startsWith('Header: Section Title'));

      // Preview contains the truncation notice and file path
      expect(preview, contains('Output truncated'));
      expect(preview, contains(files.first.path));
      expect(preview, contains('Use read tool with path: "${files.first.path}"'));

      // Preview contains the tail end
      expect(preview, contains('Line 499: Content'));
    });

    test('cleanExpired deletes files older than TTL and preserves fresh files', () async {
      final freshFile = File('${tempDir.path}/tool-fresh-output.txt');
      freshFile.writeAsStringSync('fresh content');

      final expiredFile = File('${tempDir.path}/tool-old-output.txt');
      expiredFile.writeAsStringSync('old content');
      // Set modification time to 15 minutes ago
      expiredFile.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 15)));

      await service.cleanExpired();

      expect(freshFile.existsSync(), isTrue);
      expect(expiredFile.existsSync(), isFalse);
    });

    test('sanitizes call IDs containing invalid filesystem characters', () async {
      const dirtyId = 'call:123/456*foo';
      final largeText = 'A' * 5000;

      await service.processOutput(
        callId: dirtyId,
        output: largeText,
      );

      final files = tempDir.listSync().whereType<File>().toList();
      expect(files.length, equals(1));
      expect(files.first.path, contains('tool-call_123_456_foo-output.txt'));
    });
  });

  group('readTool with spilled cache files', () {
    test('read tool can read and grep spilled cache files directly', () async {
      final largeLines = [
        'START_OF_FILE',
        for (var i = 0; i < 400; i++) 'Row $i: data payload',
        'TARGET_SECRET_KEY=sk-test-123456789',
        for (var i = 401; i < 600; i++) 'Row $i: trailing data',
        'END_OF_FILE',
      ].join('\n');

      final preview = await service.processOutput(
        callId: 'call_spill_test',
        output: largeLines,
      );

      // Extract the file path from preview
      final match = RegExp(r'Full output saved to: (.*?) \(TTL:').firstMatch(preview);
      expect(match, isNotNull);
      final spilledPath = match!.group(1)!;

      // Now create read tool and read the spilled file
      final read = readTool(WorkingDirectory(tempDir));

      final readRes = await read.handler(
        ToolCall(
          id: 'read_call_1',
          name: 'read',
          arguments: {
            'path': spilledPath,
            'grep': 'TARGET_SECRET_KEY',
          },
        ),
      );

      expect(readRes.ok, isTrue);
      expect(readRes.output, contains('TARGET_SECRET_KEY=sk-test-123456789'));
      expect(readRes.output, isNot(contains('Row 100')));
    });
  });

  group('ToolRegistry execution integration', () {
    test('automatically spills large output from any registered tool', () async {
      // Use singleton service with override temp dir for this test
      ToolOutputFileService.instance.overrideDirectory = tempDir;

      final dummyTool = Tool(
        name: 'huge_dumper',
        description: 'Dumps a lot of text',
        parameters: const {'type': 'object', 'properties': {}},
        handler: (call) async {
          return ToolCallResult(
            id: call.id,
            ok: true,
            output: 'Header: System Info\n${'Data row\n' * 1200}', // > 8000 chars
          );
        },
      );

      final registry = ToolRegistry([dummyTool]);
      final result = await registry.execute(
        const ToolCall(id: 'exec_call_99', name: 'huge_dumper', arguments: {}),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Output truncated'));
      expect(result.output, contains('tool-exec_call_99-output.txt'));
      expect(result.output, startsWith('Header: System Info'));

      // Restore
      ToolOutputFileService.instance.overrideDirectory = null;
    });
  });
}
