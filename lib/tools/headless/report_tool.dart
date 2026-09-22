import 'dart:io';

import 'package:errand/agent/tool.dart';
import 'package:errand/types/tool.dart';
import 'package:path/path.dart' as p;

/// Per-run record of the report file a headless turn saved via [saveReportTool].
///
/// Created by the runner, handed to the tool, read back after the turn.
/// No filesystem guessing, no time windows.
class HeadlessReportCollector {
  /// Absolute path of the most recently saved report, if any.
  String? reportPath;
}

/// Builds the headless-only `save_report` tool: the single blessed way for a
/// background turn to persist its full report.
///
/// The model supplies content plus an optional short name and format; all
/// path decisions are made deterministically here:
/// `<scratchDir>/task-<taskId>-<startedAtMillis>[-<sanitized-name>].<ext>`.
///
/// Last call wins. The runner falls back to writing the final answer text to
/// the default path when the tool is never called.
Tool saveReportTool({
  required Directory scratchDir,
  required int taskId,
  required int startedAtMillis,
  required HeadlessReportCollector collector,
}) {
  const allowedTypes = {'md', 'html', 'txt'};

  return Tool(
    name: 'save_report',
    description:
        'Saves your full task report to a file. Call this ONCE at the end of the turn '
        'with the complete report content — never write report files via bash. '
        'The file is saved under the task prefix so it is always found; an optional short '
        'name (letters, numbers, dashes only) is appended for readability. '
        'If you call this multiple times, the LAST call wins and earlier content is replaced. '
        'Your final turn response text is still collected separately as the user-facing summary.',
    parameters: {
      'type': 'object',
      'properties': {
        'content': {
          'type': 'string',
          'description': 'The complete report content to save.',
        },
        'name': {
          'type': 'string',
          'description':
              'Optional short label appended to the filename (e.g. "summary", "prices"). '
              'Letters, numbers, dashes and underscores only; anything else is stripped.',
        },
        'type': {
          'type': 'string',
          'enum': ['md', 'html', 'txt'],
          'description': 'Report format. Use html for charts, styled tables, or dashboards; md otherwise.',
          'default': 'md',
        },
      },
      'required': ['content'],
    },
    handler: (call) async {
      final rawContent = call.arguments['content'];
      final content = rawContent is String ? rawContent : rawContent?.toString();
      if (content == null || content.trim().isEmpty) {
        return ToolCallResult.failure(call.id, 'Content cannot be empty.');
      }
      if (content.length > maxReportChars) {
        return ToolCallResult.failure(
          call.id,
          'Content too large (${content.length} chars, max $maxReportChars). Split or shorten the report.',
        );
      }

      final rawType = call.arguments['type'];
      final typeStr = (rawType is String ? rawType : rawType?.toString() ?? 'md')
          .trim()
          .toLowerCase();
      final type = allowedTypes.contains(typeStr) ? typeStr : 'md';

      final rawName = call.arguments['filename'] ?? call.arguments['name'];
      final suffix = sanitizeReportName(
        rawName is String ? rawName : rawName?.toString() ?? '',
      );

      final filename = suffix.isNotEmpty
          ? 'task-$taskId-$startedAtMillis-$suffix.$type'
          : 'task-$taskId-$startedAtMillis.$type';
      final reportFile = File(p.join(scratchDir.path, filename));
      try {
        await reportFile.parent.create(recursive: true);
        await reportFile.writeAsString(content, flush: true);
      } catch (e) {
        return ToolCallResult.failure(
          call.id,
          'Failed to save report to ${reportFile.path}: $e',
        );
      }

      collector.reportPath = reportFile.path;
      return ToolCallResult(
        id: call.id,
        ok: true,
        output: 'Report saved to ${reportFile.path}',
      );
    },
  );
}

/// Maximum report content size accepted by [saveReportTool] (~500KB of text).
const int maxReportChars = 500000;

/// Reduces a model-supplied label to a safe filename suffix:
/// basename only, extension stripped, `[A-Za-z0-9_-]` kept, capped at 40 chars.
String sanitizeReportName(String raw) {
  var name = raw.trim();
  // Drop any directory components and traversal attempts: keep text after the
  // last separator, then strip any remaining dots but the extension split.
  name = name.split(RegExp(r'[/\\]')).last;
  // Strip a trailing extension if present (handler appends the real one).
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
}
