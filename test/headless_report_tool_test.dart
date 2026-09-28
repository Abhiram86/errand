import 'dart:io';

import 'package:errand/agent/tool.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/headless/report_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('saveReportTool', () {
    late Directory tempDir;
    late Directory scratchDir;
    late HeadlessReportCollector collector;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_report_test_');
      scratchDir = Directory('${tempDir.path}/scratch');
      await scratchDir.create(recursive: true);
      collector = HeadlessReportCollector();
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    Tool makeTool() => saveReportTool(
          scratchDir: scratchDir,
          taskId: 42,
          startedAtMillis: 1700000000000,
          collector: collector,
        );

    test('writes content to task-prefixed timestamped file and records path', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-1',
          name: 'save_report',
          arguments: {'content': '# Hello', 'name': 'summary', 'type': 'md'},
        ),
      );

      expect(result.ok, isTrue);
      expect(collector.reportPath, isNotNull);
      expect(collector.reportPath, contains('task-42-1700000000000-summary.md'));
      expect(File(collector.reportPath!).readAsStringSync(), equals('# Hello'));
    });

    test('rejects empty content', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-2',
          name: 'save_report',
          arguments: {'content': '   '},
        ),
      );

      expect(result.ok, isFalse);
      expect(collector.reportPath, isNull);
    });

    test('sanitizes traversal and absolute paths into scratch', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-3',
          name: 'save_report',
          arguments: {'content': 'x', 'name': '../../etc/evil'},
        ),
      );

      expect(result.ok, isTrue);
      expect(collector.reportPath, isNotNull);
      // Resolved strictly under scratch with enforced prefix.
      expect(collector.reportPath!.startsWith(scratchDir.path), isTrue);
      expect(collector.reportPath, contains('task-42-1700000000000-'));
      expect(collector.reportPath, isNot(contains('..')));
      expect(File(collector.reportPath!).existsSync(), isTrue);
    });

    test('falls back to md for unknown type', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-4',
          name: 'save_report',
          arguments: {'content': 'x', 'type': 'exe'},
        ),
      );

      expect(result.ok, isTrue);
      expect(collector.reportPath!.endsWith('.md'), isTrue);
    });

    test('rejects oversized content', () async {
      final big = 'x' * (maxReportChars + 1);
      final result = await makeTool().handler(
        ToolCall(
          id: 'c-5',
          name: 'save_report',
          arguments: {'content': big},
        ),
      );

      expect(result.ok, isFalse);
      expect(collector.reportPath, isNull);
    });

    test('last call wins and strips embedded extensions', () async {
      final tool = makeTool();
      await tool.handler(
        const ToolCall(
          id: 'c-6',
          name: 'save_report',
          arguments: {'content': 'first', 'name': 'draft.html'},
        ),
      );
      final firstPath = collector.reportPath;
      await tool.handler(
        const ToolCall(
          id: 'c-7',
          name: 'save_report',
          arguments: {'content': 'second'},
        ),
      );

      expect(firstPath, contains('-draft.md'));
      expect(firstPath, isNot(contains('.html')));
      expect(collector.reportPath, contains('task-42-1700000000000.md'));
      expect(File(collector.reportPath!).readAsStringSync(), equals('second'));
    });

    test('sanitizeReportName keeps only safe chars capped at 40', () {
      expect(sanitizeReportName('My Report! 2024'), equals('MyReport2024'));
      expect(sanitizeReportName('../../a/b'), equals('b'));
      expect(sanitizeReportName('x' * 100).length, equals(40));
      expect(sanitizeReportName(''), isEmpty);
    });

    test('errors out on single missing linked file with exact path', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-8',
          name: 'save_report',
          arguments: {
            'content': 'report body',
            'linked_files': ['missing_file.html'],
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(collector.reportPath, isNull);
      expect(
        result.errorMessage,
        equals('The given path to file does not exist: check path of the file/s to "missing_file.html"'),
      );
    });

    test('accumulates all missing files without failing fast on the first', () async {
      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-9',
          name: 'save_report',
          arguments: {
            'content': 'report body',
            'linked_files': ['missing1.html', 'missing2.html', 'missing3.html'],
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(collector.reportPath, isNull);
      expect(
        result.errorMessage,
        equals(
          'The given path to file does not exist: check path of the file/s to "missing1.html", "missing2.html", "missing3.html"',
        ),
      );
    });

    test('detects multiple missing files even when one exists in the middle', () async {
      final validFile = File(p.join(scratchDir.path, 'valid.html'));
      validFile.writeAsStringSync('<h1>Valid</h1>');

      final result = await makeTool().handler(
        const ToolCall(
          id: 'c-10',
          name: 'save_report',
          arguments: {
            'content': 'report body',
            'linked_files': ['wrong1.html', 'valid.html', 'wrong3.html'],
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(collector.reportPath, isNull);
      expect(
        result.errorMessage,
        equals('The given path to file does not exist: check path of the file/s to "wrong1.html", "wrong3.html"'),
      );
    });

    test('resolves file in workingDirectory outside scratch and copies to scratch', () async {
      final workDir = Directory(p.join(tempDir.path, 'workspace'));
      await workDir.create(recursive: true);
      final cwdFile = File(p.join(workDir.path, 'page1.html'));
      cwdFile.writeAsStringSync('<h1>From CWD</h1>');

      final tool = saveReportTool(
        scratchDir: scratchDir,
        taskId: 42,
        startedAtMillis: 1700000000000,
        collector: collector,
        workingDirectory: WorkingDirectory(workDir),
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'c-11',
          name: 'save_report',
          arguments: {
            'content': 'report body',
            'linked_files': ['page1.html'],
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(collector.reportPath, isNotNull);
      // Namespaced by task+run so same-basename links never collide.
      expect(collector.linkedFiles, hasLength(1));
      expect(
        collector.linkedFiles.single,
        equals('task-42-1700000000000-link-page1.html'),
      );
      // Copied into scratch for log preview
      final scratchCopy =
          File(p.join(scratchDir.path, 'task-42-1700000000000-link-page1.html'));
      expect(scratchCopy.existsSync(), isTrue);
      expect(scratchCopy.readAsStringSync(), equals('<h1>From CWD</h1>'));
    });

    test('same-basename links from different runs do not overwrite', () async {
      final workDir = Directory(p.join(tempDir.path, 'workspace2'));
      await workDir.create(recursive: true);
      File(p.join(workDir.path, 'page1.html')).writeAsStringSync('<h1>v1</h1>');

      final toolA = saveReportTool(
        scratchDir: scratchDir,
        taskId: 7,
        startedAtMillis: 1700000000001,
        collector: collector,
        workingDirectory: WorkingDirectory(workDir),
      );
      final resA = await toolA.handler(
        const ToolCall(
          id: 'c-12a',
          name: 'save_report',
          arguments: {'content': 'a', 'linked_files': ['page1.html']},
        ),
      );
      expect(resA.ok, isTrue);
      final nameA = collector.linkedFiles.single;

      File(p.join(workDir.path, 'page1.html')).writeAsStringSync('<h1>v2</h1>');
      final collectorB = HeadlessReportCollector();
      final toolB = saveReportTool(
        scratchDir: scratchDir,
        taskId: 8,
        startedAtMillis: 1700000000002,
        collector: collectorB,
        workingDirectory: WorkingDirectory(workDir),
      );
      final resB = await toolB.handler(
        const ToolCall(
          id: 'c-12b',
          name: 'save_report',
          arguments: {'content': 'b', 'linked_files': ['page1.html']},
        ),
      );
      expect(resB.ok, isTrue);
      final nameB = collectorB.linkedFiles.single;

      expect(nameB, isNot(equals(nameA)));
      expect(File(p.join(scratchDir.path, nameA)).readAsStringSync(),
          equals('<h1>v1</h1>'));
      expect(File(p.join(scratchDir.path, nameB)).readAsStringSync(),
          equals('<h1>v2</h1>'));
    });
  });
}
