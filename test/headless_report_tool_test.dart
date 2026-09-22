import 'dart:io';

import 'package:errand/agent/tool.dart';
import 'package:errand/tools/headless/report_tool.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
