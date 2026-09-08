import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../types/tool.dart';

/// Service that spills large tool outputs (> thresholdChars) into a temporary cache
/// file (`cache/tool_outputs/tool-<callId>-output.txt`) with a 10-minute TTL.
///
/// Returns a concise preview combining the initial [headChars] (preserving headers)
/// and final [tailChars], with the saved file path so the agent can use the `read` tool
/// (with offset/length or grep) to inspect specific parts without blowing context tokens.
class ToolOutputFileService {
  Directory? overrideDirectory;
  final int thresholdChars;
  final int headChars;
  final int tailChars;
  final Duration ttl;

  ToolOutputFileService({
    this.overrideDirectory,
    this.thresholdChars = 6000,
    this.headChars = 2000,
    this.tailChars = 2000,
    this.ttl = const Duration(minutes: 10),
  });

  static final ToolOutputFileService instance = ToolOutputFileService();

  /// Resolves the directory where tool output files are cached.
  Future<Directory> get outputDirectory async {
    if (overrideDirectory != null) {
      if (!await overrideDirectory!.exists()) {
        await overrideDirectory!.create(recursive: true);
      }
      return overrideDirectory!;
    }
    Directory baseDir;
    try {
      baseDir = await getApplicationCacheDirectory();
    } catch (_) {
      try {
        baseDir = await getTemporaryDirectory();
      } catch (_) {
        baseDir = Directory.systemTemp;
      }
    }
    final dir = Directory(p.join(baseDir.path, 'tool_outputs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cleans up cached output files older than [ttl].
  Future<void> cleanExpired() async {
    try {
      final dir = await outputDirectory;
      if (!await dir.exists()) return;
      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.txt')) {
          try {
            final stat = await entity.stat();
            if (now.difference(stat.modified) > ttl) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Sanitizes tool call IDs for use in filenames.
  static String sanitizeCallId(String callId) {
    return callId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  /// Checks if [output] exceeds [thresholdChars]. If so, saves it to a cache file
  /// and returns a preview of [headChars] + truncation notice with file path + [tailChars].
  Future<String> processOutput({
    required String callId,
    required String output,
  }) async {
    if (output.length <= thresholdChars) {
      return output;
    }

    // Clean up expired cache files in the background.
    cleanExpired().ignore();

    final dir = await outputDirectory;
    final cleanId = sanitizeCallId(callId);
    final file = File(p.join(dir.path, 'tool-$cleanId-output.txt'));

    await file.writeAsString(output, flush: true);

    return generatePreview(output, file);
  }

  /// Generates the head + tail preview with truncation banner and file path.
  String generatePreview(String text, File file) {
    final totalChars = text.length;
    if (totalChars <= headChars + tailChars) {
      return text;
    }

    var headCut = headChars;
    final lastNewlineInHead = text.lastIndexOf('\n', headCut);
    if (lastNewlineInHead > headCut - 300 && lastNewlineInHead > 0) {
      headCut = lastNewlineInHead;
    }
    final head = text.substring(0, headCut).trimRight();

    var tailStart = totalChars - tailChars;
    final firstNewlineInTail = text.indexOf('\n', tailStart);
    if (firstNewlineInTail != -1 && firstNewlineInTail < tailStart + 300) {
      tailStart = firstNewlineInTail + 1;
    }
    final tail = text.substring(tailStart).trimLeft();

    final tailCharsShown = totalChars - tailStart;

    return '$head\n\n'
        '[... Output truncated: showing first $headCut and last $tailCharsShown of $totalChars characters.\n'
        'Full output saved to: ${file.path} (TTL: 10m).\n'
        'Use read tool with path: "${file.path}" (supports grep, offset, length) to inspect further. ...]\n\n'
        '$tail';
  }

  /// Wraps a [ToolCallResult], replacing [result.output] with the spilled preview
  /// if it exceeds [thresholdChars].
  Future<ToolCallResult> maybeSpillResult(
    ToolCallResult result, {
    required String callId,
  }) async {
    if (!result.ok || result.output.length <= thresholdChars) {
      return result;
    }

    final preview = await processOutput(
      callId: callId,
      output: result.output,
    );

    return ToolCallResult(
      id: result.id,
      ok: result.ok,
      output: preview,
      contentParts: result.contentParts,
      error: result.error,
    );
  }
}
