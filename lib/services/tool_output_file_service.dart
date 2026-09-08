import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../types/tool.dart';

/// Service that spills large tool outputs (> thresholdChars) into a temporary cache
/// file (`cache/tool_outputs/tool-<callId>-output.txt`) with a 10-minute TTL.
///
/// Returns a concise preview combining the leading [headChars] (with the
/// metadata header block reserved first — e.g. `File:`/`Source:`/`Screen:`
/// lines the agent needs for follow-up reads) and final [tailChars], with the
/// saved file path so the agent can use the `read` tool (with offset/length
/// or grep) to inspect specific parts without blowing context tokens.
///
/// Sweep is opportunistic: expired/over-cap files are deleted on the next
/// large-output spill (no background timer).
class ToolOutputFileService {
  Directory? overrideDirectory;
  final int thresholdChars;
  final int headChars;
  final int tailChars;
  final Duration ttl;

  /// Max spill files kept; oldest beyond this are deleted on sweep.
  final int maxFiles;

  /// Max chars stored per spill file (disk/memory guard).
  static const int kMaxStoredChars = 512 * 1024;

  /// Header block (up to first blank line) is always reserved in previews
  /// when it fits within this budget.
  static const int kMaxHeaderChars = 1500;

  ToolOutputFileService({
    this.overrideDirectory,
    this.thresholdChars = 6000,
    this.headChars = 2000,
    this.tailChars = 2000,
    this.ttl = const Duration(minutes: 10),
    this.maxFiles = 50,
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

  /// Deletes expired files and oldest files beyond [maxFiles].
  Future<void> cleanExpired() async {
    try {
      final dir = await outputDirectory;
      if (!await dir.exists()) return;
      final now = DateTime.now();
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.txt')) {
          try {
            final stat = await entity.stat();
            if (now.difference(stat.modified) > ttl) {
              await entity.delete();
              continue;
            }
            files.add(entity);
          } catch (_) {}
        }
      }
      if (files.length > maxFiles) {
        files.sort((a, b) {
          try {
            return b.statSync().modified.compareTo(a.statSync().modified);
          } catch (_) {
            return 0;
          }
        });
        for (final extra in files.sublist(maxFiles)) {
          try {
            await extra.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Sanitizes tool call IDs for use in filenames (truncated + hashed so
  /// distinct ids never collide and long model-influenced ids fit).
  static String sanitizeCallId(String callId) {
    return callId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  /// Deterministic filename for [callId]: truncated sanitized id + short
  /// hash of the full id (collision-proof, ENAMETOOLONG-safe).
  static String fileNameForCallId(String callId) {
    final clean = sanitizeCallId(callId);
    final truncated =
        clean.length > 48 ? clean.substring(0, 48) : clean;
    var hash = 0;
    for (var i = 0; i < callId.length; i++) {
      hash = ((hash << 5) - hash + callId.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return 'tool-${truncated}_${hash.toRadixString(16)}-output.txt';
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

    // Sweep expired/over-cap files in the background (fire-and-forget).
    unawaited(cleanExpired());

    final dir = await outputDirectory;
    final file = File(p.join(dir.path, fileNameForCallId(callId)));

    var stored = output;
    if (stored.length > kMaxStoredChars) {
      stored =
          '${stored.substring(0, kMaxStoredChars)}\n\n[... stored output truncated at $kMaxStoredChars chars of ${output.length} ...]';
    }
    // Atomic write: tmp + rename so concurrent retries never leave torn files.
    final tmp = File('${file.path}.part');
    await tmp.writeAsString(stored, flush: true);
    await tmp.rename(file.path);

    return generatePreview(output, file);
  }

  /// Generates the head + tail preview with truncation banner and file path.
  /// The leading metadata header block (up to the first blank line, when it
  /// fits in [kMaxHeaderChars]) is always reserved first — it carries the
  /// `File:`/`Source:`/`Screen:` context the agent needs for follow-ups.
  String generatePreview(String text, File file) {
    final totalChars = text.length;
    if (totalChars <= headChars + tailChars) {
      return text;
    }

    var headerBlock = '';
    var body = text;
    final blankIdx = text.indexOf('\n\n');
    if (blankIdx > 0 && blankIdx <= kMaxHeaderChars) {
      headerBlock = text.substring(0, blankIdx);
      body = text.substring(blankIdx + 2);
    }

    var headCut = headChars;
    final headLimit = headCut.clamp(0, body.length).toInt();
    final lastNewlineInHead = body.lastIndexOf('\n', headLimit);
    if (lastNewlineInHead > headCut - 300 && lastNewlineInHead > 0) {
      headCut = lastNewlineInHead;
    }
    final head =
        body.substring(0, headCut.clamp(0, body.length).toInt()).trimRight();

    var tailStart = totalChars - tailChars;
    final firstNewlineInTail = text.indexOf('\n', tailStart);
    if (firstNewlineInTail != -1 && firstNewlineInTail < tailStart + 300) {
      tailStart = firstNewlineInTail + 1;
    }
    final tail = text.substring(tailStart).trimLeft();

    final tailCharsShown = totalChars - tailStart;
    final headSection = headerBlock.isEmpty ? head : '$headerBlock\n\n$head';

    return '$headSection\n\n'
        '[... Output truncated: showing first $headCut and last $tailCharsShown of $totalChars characters.\n'
        'Full output saved to: ${file.path} (TTL: ${ttl.inMinutes}m).\n'
        'Use read tool with path: "${file.path}" (supports grep, offset, length) to inspect further. ...]\n\n'
        '$tail';
  }

  /// Wraps a [ToolCallResult], replacing [result.output] with the spilled preview
  /// if it exceeds [thresholdChars]. Already-spilled previews (containing the
  /// `Full output saved to:` banner) pass through untouched so per-tool spills
  /// and this safety net never overwrite each other regardless of thresholds.
  Future<ToolCallResult> maybeSpillResult(
    ToolCallResult result, {
    required String callId,
  }) async {
    if (!result.ok || result.output.length <= thresholdChars) {
      return result;
    }
    if (result.output.contains('Full output saved to:')) {
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
