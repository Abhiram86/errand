import 'dart:io';

import 'package:errand/agent/tool.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/types/tool.dart';
import 'package:path/path.dart' as p;

/// Per-run record of the report file a headless turn saved via [saveReportTool].
///
/// Created by the runner, handed to the tool, read back after the turn.
/// No filesystem guessing, no time windows.
class HeadlessReportCollector {
  /// Absolute path of the most recently saved report, if any.
  String? reportPath;

  /// Additional auxiliary files generated or linked during the run.
  final List<String> linkedFiles = [];
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
  WorkingDirectory? workingDirectory,
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
        'linked_files': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Optional list of auxiliary file paths created during the task (e.g. CSVs, charts, exports, downloaded files) '
              'to link with this report for user download, preview, and tracking.',
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

      final rawLinked = call.arguments['linked_files'];
      final validatedFiles = <({File file, String originalPath})>[];
      final missingFiles = <String>[];

      if (rawLinked is List) {
        for (final item in rawLinked) {
          if (item == null) continue;
          final pathStr = item.toString().trim();
          if (pathStr.isEmpty) continue;

          final resolved = resolveExistingLinkedFile(
            pathStr,
            scratchDir: scratchDir,
            workingDirectory: workingDirectory,
          );
          if (resolved == null) {
            missingFiles.add(pathStr);
          } else {
            validatedFiles.add((file: resolved, originalPath: pathStr));
          }
        }
      }

      if (missingFiles.isNotEmpty) {
        final fileListStr = missingFiles.map((f) => '"$f"').join(', ');
        return ToolCallResult.failure(
          call.id,
          'The given path to file does not exist: check path of the file/s to $fileListStr',
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
      collector.linkedFiles.clear();

      for (final entry in validatedFiles) {
        final file = entry.file;
        if (p.isWithin(scratchDir.path, file.path)) {
          collector.linkedFiles.add(p.relative(file.path, from: scratchDir.path));
        } else {
          // If file was created outside scratchDir (e.g. in working dir), copy into scratchDir
          // so task log preview & report cleanup work deterministically.
          // Copy name is namespaced by task+run so two runs linking the
          // same basename (e.g. page1.html) never overwrite each other.
          final linkBase = sanitizeReportName(p.basenameWithoutExtension(file.path));
          final linkExt = p.extension(file.path).replaceAll(RegExp(r'[^A-Za-z0-9.]'), '');
          final linkName =
              'task-$taskId-$startedAtMillis-link-${linkBase.isNotEmpty ? linkBase : 'file'}$linkExt';
          final scratchCopy = File(p.join(scratchDir.path, linkName));
          try {
            if (!scratchCopy.existsSync() || scratchCopy.path != file.path) {
              await file.copy(scratchCopy.path);
            }
            collector.linkedFiles.add(linkName);
          } catch (_) {
            collector.linkedFiles.add(entry.originalPath);
          }
        }
      }

      return ToolCallResult(
        id: call.id,
        ok: true,
        output: 'Report saved to ${reportFile.path}',
      );
    },
  );
}

/// Resolves a candidate linked file path on disk against scratchDir,
/// workingDirectory, or as an absolute path. Returns null if the file does not exist.
File? resolveExistingLinkedFile(
  String rawPath, {
  required Directory scratchDir,
  WorkingDirectory? workingDirectory,
}) {
  var cleanPath = rawPath.trim();
  if (cleanPath.startsWith('file://')) {
    final uri = Uri.tryParse(cleanPath);
    if (uri != null && uri.path.isNotEmpty) {
      cleanPath = uri.toFilePath();
    } else {
      cleanPath = cleanPath.replaceFirst(RegExp(r'^file://+'), '/');
    }
  }

  // 1. Direct / Absolute check
  if (p.isAbsolute(cleanPath)) {
    final direct = File(cleanPath);
    if (direct.existsSync()) return direct;
  }

  // 2. Relative to scratchDir
  final inScratch = File(p.normalize(p.join(scratchDir.path, cleanPath)));
  if (inScratch.existsSync()) return inScratch;

  // 3. Traversal / prefix relative to scratch parent (e.g. ".scratch/file.xxx" or "scratch/file.xxx")
  if (cleanPath.startsWith('.scratch/') || cleanPath.startsWith('scratch/')) {
    final fromParent = File(p.normalize(p.join(scratchDir.parent.path, cleanPath)));
    if (fromParent.existsSync()) return fromParent;

    final stripped = cleanPath.replaceFirst(RegExp(r'^\.?scratch/'), '');
    final inScratchStripped = File(p.normalize(p.join(scratchDir.path, stripped)));
    if (inScratchStripped.existsSync()) return inScratchStripped;
  }

  // 4. Working directory checks (where bash commands execute)
  if (workingDirectory != null) {
    final inCwd = File(p.normalize(p.join(workingDirectory.current.path, cleanPath)));
    if (inCwd.existsSync()) return inCwd;

    if (workingDirectory.root.path != workingDirectory.current.path) {
      final inRoot = File(p.normalize(p.join(workingDirectory.root.path, cleanPath)));
      if (inRoot.existsSync()) return inRoot;
    }
  }

  // 5. Check process current directory
  final inProcessCwd = File(p.normalize(p.join(Directory.current.path, cleanPath)));
  if (inProcessCwd.existsSync()) return inProcessCwd;

  return null;
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
