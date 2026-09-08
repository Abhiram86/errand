import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../agent/tool.dart';
// import '../services/workspace.dart';
import '../types/tool.dart';
import '../internal/document_reading/document_reader.dart';
import 'grep_filter.dart';

import 'package:path/path.dart' as path;

const kMaxReadBytes = 512 * 1024;

/// Media files are read whole and base64-encoded into content parts; this
/// caps the raw (pre-base64) size. 20MB matches the strictest common
/// provider payload limit.
const kMaxMediaBytes = 20 * 1024 * 1024;

/// The "big" formats per modality — the ones every multimodal provider
/// accepts. Anything else falls through to the text/structured readers and
/// fails honestly there.
const kMediaFormats = <String, ({String modality, String mime, String? format})>{
  // Images: universally supported vision MIME types.
  '.jpg': (modality: 'image', mime: 'image/jpeg', format: null),
  '.jpeg': (modality: 'image', mime: 'image/jpeg', format: null),
  '.png': (modality: 'image', mime: 'image/png', format: null),
  '.webp': (modality: 'image', mime: 'image/webp', format: null),
  '.gif': (modality: 'image', mime: 'image/gif', format: null),
  // Audio: input_audio takes raw base64 plus a format tag. wav/mp3 are the
  // OpenAI-compatible baseline; m4a/aac/ogg/flac only on some providers
  // (e.g. Gemini) — kept out of the big set on purpose.
  '.wav': (modality: 'audio', mime: 'audio/wav', format: 'wav'),
  '.mp3': (modality: 'audio', mime: 'audio/mpeg', format: 'mp3'),
  // Video: OpenRouter-style video_url with a data URL.
  '.mp4': (modality: 'video', mime: 'video/mp4', format: null),
  '.webm': (modality: 'video', mime: 'video/webm', format: null),
  '.mov': (modality: 'video', mime: 'video/quicktime', format: null),
};

class WorkingDirectory {
  final Directory root;
  Directory current;

  WorkingDirectory(this.root, {Directory? current}) : current = current ?? root;
}

class _CachedStructuredDocument {
  final DateTime lastModified;
  final int fileLength;
  final LogicalDocument document;

  _CachedStructuredDocument({
    required this.lastModified,
    required this.fileLength,
    required this.document,
  });
}

Tool readTool(
  WorkingDirectory workspace, {
  /// Reports whether the CURRENT model claims support for an input modality
  /// ("image"/"audio"/"video"). Null = unknown (endpoint doesn't report
  /// architecture) — allow the attempt. Wired from ModelCatalogService in
  /// main.dart so the tool can fail honestly before burning a turn.
  bool Function(String modality)? supportsInput,
  List<String> Function()? getAttachedFiles,
}) {
  final structuredDocuments = <String, _CachedStructuredDocument>{};

  return Tool(
    name: 'read',
    onDispose: () {
      for (final cached in structuredDocuments.values) {
        cached.document.dispose();
      }
      structuredDocuments.clear();
    },
    description:
        'Reads the contents of a specific file inside the workspace or an attached file. '
        'Requires "path". Supports text files, documents (PDF, DOCX, XLSX, PPTX), '
        'and media (images, audio, video). Do NOT use on directories (use "workspace" '
        'action:"list" instead). For text files, offset and length are byte-based; '
        'for structured documents, offset is page/section index. For media files, '
        'call without offset/length.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Relative path or absolute path inside the workspace',
        },
        'offset': {
          'type': 'integer',
          'description':
              'Byte offset for text files, or logical page/slide/section offset '
              'for structured files',
          'default': 0,
        },
        'length': {
          'type': 'integer',
          'description':
              'Maximum bytes for text files, or maximum extracted characters '
              'for structured files',
          'default': 512,
        },
        'grep': {
          'type': 'string',
          'description':
              'Optional case-insensitive regular expression or substring filter. '
              'When provided, returns only matching lines from the file content.',
        },
      },
      'required': ['path'],
    },
    handler: (call) async {
      final rawPath = (call.arguments['path'] as String?)?.trim();
      final offset = (call.arguments['offset'] as num?)?.toInt() ?? 0;
      final grep = (call.arguments['grep'] as String?)?.trim();
      final hasGrep = grep != null && grep.isNotEmpty;
      final length = (call.arguments['length'] as num?)?.toInt() ??
          (hasGrep ? kMaxReadBytes : 512);

      // Validate arguments.
      if (rawPath == null || rawPath.isEmpty) {
        return ToolCallResult.failure(
          call.id,
          'Invalid path: path cannot be empty.',
        );
      }

      if (offset < 0) {
        return ToolCallResult.failure(
          call.id,
          'Invalid offset: offset must be >= 0.',
        );
      }

      if (length <= 0) {
        return ToolCallResult.failure(
          call.id,
          'Invalid length: length must be > 0.',
        );
      }

      if (length > kMaxReadBytes) {
        return ToolCallResult.failure(
          call.id,
          'Invalid length: maximum readable range is $kMaxReadBytes bytes.',
        );
      }

      final file = await _resolveReadableFile(workspace, rawPath, getAttachedFiles);
      if (file == null || !await file.exists()) {
        return ToolCallResult.failure(
          call.id,
          'File not found or outside the workspace: $rawPath',
        );
      }

      try {
        // -- Media branch (P3): whole-file read delivered as content parts --
        final media = kMediaFormats[path.extension(file.path).toLowerCase()];
        if (media != null) {
          return await _readMediaFile(
            call, file, media, supportsInput,
          );
        }

        final stat = await file.stat();
        final cached = structuredDocuments[file.path];
        LogicalDocument? document;

        if (cached != null &&
            cached.lastModified == stat.modified &&
            cached.fileLength == stat.size) {
          document = cached.document;
        } else {
          cached?.document.dispose();
          document = await readStructuredDocument(file);
          if (document != null) {
            if (structuredDocuments.length >= 10) {
              final oldestKey = structuredDocuments.keys.first;
              structuredDocuments.remove(oldestKey)?.document.dispose();
            }
            structuredDocuments[file.path] = _CachedStructuredDocument(
              lastModified: stat.modified,
              fileLength: stat.size,
              document: document,
            );
          } else {
            structuredDocuments.remove(file.path);
          }
        }

        final structured = document?.read(offset: offset, length: length);
        if (structured != null) {
          final outputText = structured.toToolOutput(file.path);
          if (hasGrep) {
            final filtered = GrepFilter.filter(
              outputText,
              grep,
              header: 'File: ${file.path}',
              withLineNumbers: true,
            );
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: filtered,
            );
          }
          return ToolCallResult(
            id: call.id,
            ok: true,
            output: outputText,
          );
        }

        final totalBytes = await file.length();

        if (offset >= totalBytes) {
          return ToolCallResult.failure(
            call.id,
            'Offset $offset is beyond the end of the file '
            '(file size: $totalBytes bytes).',
          );
        }

        final end = min(offset + length, totalBytes);

        // Read only the requested range.
        final raf = await file.open();
        try {
          await raf.setPosition(offset);
          final bytes = await raf.read(end - offset);

          final text = utf8.decode(bytes, allowMalformed: true);

          if (hasGrep) {
            final header = 'File: ${file.path} (read $offset–$end of $totalBytes bytes)';
            final filtered = GrepFilter.filter(
              text,
              grep,
              header: header,
              withLineNumbers: true,
            );
            return ToolCallResult(id: call.id, ok: true, output: filtered);
          }

          final nextOffset = offset + bytes.length;
          final hasMore = nextOffset < totalBytes;

          final formatted =
              '''
          File: ${file.path}
          Total size: $totalBytes bytes
          Reading bytes $offset–$nextOffset (${bytes.length} bytes)
          ${hasMore ? 'More content available from byte $nextOffset.' : 'End of file reached.'}

          $text
        ''';

          return ToolCallResult(id: call.id, ok: true, output: formatted);
        } finally {
          await raf.close();
        }
      } catch (e) {
        return ToolCallResult.failure(
          call.id,
          'Failed to read "${file.path}": $e',
        );
      }
    },
  );
}

const kDefaultListLimit = 25;

Tool listTool(WorkingDirectory workspace) => Tool(
  name: 'list',
  description:
      'Lists files and directories. Without path, lists the current directory. '
      'A relative path is resolved from the current directory; an absolute '
      'path may be used for another location inside the workspace. If a '
      'pattern is provided, only matching paths are returned. Returns up to '
      'limit entries starting at offset, plus the total count in the header; '
      'use count_only=true to get just the number. Only raise limit when the '
      'task requires exhaustive enumeration.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'Optional directory path. Relative paths start at the current '
            'directory; absolute paths must stay inside the workspace root.',
      },
      'pattern': {
        'type': 'string',
        'description':
            'Optional Dart RegExp pattern used to filter file paths.',
      },
      'count_only': {
        'type': 'boolean',
        'description':
            'When true, returns only the total entry count without listing '
            'paths.',
        'default': false,
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of entries to return per call.',
        'default': kDefaultListLimit,
        'minimum': 1,
      },
      'offset': {
        'type': 'integer',
        'description':
            'Number of entries to skip before returning results. Use the '
            'offset from the continuation hint in the output for the next '
            'page.',
        'default': 0,
        'minimum': 0,
      },
      'grep': {
        'type': 'string',
        'description':
            'Optional case-insensitive regular expression or substring filter to '
            'filter returned directory entries.',
      },
    },
  },
  handler: (call) async {
    final rawPath = (call.arguments['path'] as String?)?.trim();
    final pattern = call.arguments['pattern'] as String?;
    final countOnly = (call.arguments['count_only'] as bool?) ?? false;
    final limit = min((call.arguments['limit'] as num?)?.toInt() ?? kDefaultListLimit, kMaxFindResults);
    final offset = (call.arguments['offset'] as num?)?.toInt() ?? 0;

    if (offset < 0) {
      return ToolCallResult.failure(
        call.id,
        'Invalid offset: offset must be >= 0.',
      );
    }
    if (limit <= 0) {
      return ToolCallResult.failure(
        call.id,
        'Invalid limit: limit must be > 0.',
      );
    }

    final target = _resolveListDirectory(workspace, rawPath);
    if (target == null) {
      return ToolCallResult.failure(
        call.id,
        'Invalid path: it must stay inside the workspace root.',
      );
    }

    RegExp? re;

    if (pattern != null && pattern.isNotEmpty) {
      try {
        re = RegExp(pattern);
      } catch (e) {
        return ToolCallResult.failure(
          call.id,
          'Invalid RegExp pattern "$pattern": $e',
        );
      }
    }

    final results = <String>[];

    try {
      if (!await target.exists()) {
        return ToolCallResult.failure(
          call.id,
          'Directory not found: ${target.path}',
        );
      }

      if (!await target.stat().then(
        (stat) => stat.type == FileSystemEntityType.directory,
      )) {
        return ToolCallResult.failure(
          call.id,
          'Not a directory: ${target.path}',
        );
      }

      await for (final entity in target.list()) {
        final relativePath = path.relative(
          entity.path,
          from: workspace.current.path,
        );

        if (re != null && !re.hasMatch(relativePath)) {
          continue;
        }

        results.add(relativePath);
      }
    } catch (e) {
      return ToolCallResult.failure(
        call.id,
        'Failed to list current directory: $e',
      );
    }

    // Deterministic order before windowing: Directory.list() order is
    // filesystem-dependent, and offset paging over it can overlap or skip
    // entries between calls.
    results.sort();

    final total = results.length;
    final start = min(offset, total);
    final end = min(start + limit, total);
    final window = results.sublist(start, end);

    var outputEntries = window;
    final grep = (call.arguments['grep'] as String?)?.trim();
    if (grep != null && grep.isNotEmpty) {
      final filteredText = GrepFilter.filter(window.join('\n'), grep);
      outputEntries = filteredText.split('\n');
    }

    final header = [
      'current directory: ${target.path}',
      'found $total file(s)',
      if (countOnly)
        'count only; no entries listed'
      else if (window.isEmpty && total > 0)
        'offset $offset is beyond the last entry ($total total); use offset < $total'
      else ...[
        'showing ${start + 1}–$end of $total',
        if (end < total) 'use offset=$end for the next page',
      ],
    ];
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: countOnly ? header.join('\n') : [...header, ...outputEntries].join('\n'),
    );
  },
);

/// Reads a media file whole and returns it as OpenAI-compatible content
/// parts. [output] stays a short text summary (the durable record shown in
/// the UI and persisted); the bytes ride in [ToolCallResult.contentParts] as:
/// - images:  `{type:"image_url", image_url:{url:"data:<mime>;base64,..."}}`
/// - audio:   `{type:"input_audio", input_audio:{data:"<base64>", format:..}}`
/// - video:   `{type:"video_url", video_url:{url:"data:<mime>;base64,..."}}`
Future<ToolCallResult> _readMediaFile(
  ToolCall call,
  File file,
  ({String modality, String mime, String? format}) media,
  bool Function(String modality)? supportsInput,
) async {
  final claimed = supportsInput?.call(media.modality);
  if (claimed == false) {
    return ToolCallResult.failure(
      call.id,
      'This file is a ${media.modality} (${path.basename(file.path)}), but the '
      'current model does not support ${media.modality} input. Tell the user to '
      'switch to a model with ${media.modality} support (e.g. filter the model '
      'picker) and retry.',
      type: 'unsupported_modality',
    );
    // claimed == null means the endpoint doesn't report architecture — let it
    // ride; the provider will error honestly if it truly can't.
  }

  final size = await file.length();
  if (size > kMaxMediaBytes) {
    return ToolCallResult.failure(
      call.id,
      'Media file too large: ${(size / 1048576).round()}MB, must be <= '
      '${kMaxMediaBytes ~/ 1048576}MB.',
    );
  }

  final bytes = await file.readAsBytes();
  final base64Data = base64Encode(bytes);

  Map<String, dynamic> part;
  switch (media.modality) {
    case 'image':
      part = {
        'type': 'image_url',
        'image_url': {'url': 'data:${media.mime};base64,$base64Data'},
      };
    case 'audio':
      part = {
        'type': 'input_audio',
        'input_audio': {'data': base64Data, 'format': media.format},
      };
    case 'video':
      part = {
        'type': 'video_url',
        'video_url': {'url': 'data:${media.mime};base64,$base64Data'},
      };
    default:
      return ToolCallResult.failure(
        call.id,
        'Unsupported media modality: ${media.modality}',
      );
  }

  final kb = (bytes.length / 1024).round();
  return ToolCallResult(
    id: call.id,
    ok: true,
    output: '${media.modality} file loaded for you: '
        '"${path.basename(file.path)}" (${media.mime}, $kb KB). It is attached '
        'to this conversation turn — analyze/describe it directly.',
    contentParts: [part],
  );
}

Future<File?> _resolveReadableFile(
  WorkingDirectory workspace,
  String rawPath,
  List<String> Function()? getAttachedFiles,
) async {
  var cleanPath = rawPath.trim();
  if (cleanPath.startsWith('file://')) {
    try {
      cleanPath = Uri.parse(cleanPath).toFilePath();
    } catch (_) {
      cleanPath = cleanPath.substring('file://'.length);
    }
  }

  final workspaceFile = _resolveWorkspaceFile(workspace, cleanPath);
  if (workspaceFile != null) return workspaceFile;
  // Fallback for file_picker cache copies (e.g. /data/user/0/.../cache/file_picker/...)
  // and any explicitly attached URI — the user picked it, so allow it even
  // though it lives outside /storage/emulated/0.
  if (path.isAbsolute(cleanPath)) {
    final attached = getAttachedFiles?.call() ?? const <String>[];
    final isAttached = attached.any((u) {
      var norm = u.trim();
      if (norm.startsWith('file://')) {
        try {
          norm = Uri.parse(norm).toFilePath();
        } catch (_) {
          norm = norm.substring('file://'.length);
        }
      }
      return path.normalize(norm) == path.normalize(cleanPath);
    });
    // Also allow bare /data/... cache paths without needing the callback
    // (covers legacy attachments before this callback was wired).
    final isPickerCache =
        cleanPath.startsWith('/data/') && cleanPath.contains('/cache/');
    if ((isAttached || isPickerCache) && await File(cleanPath).exists()) {
      return File(path.normalize(cleanPath));
    }
  }
  return null;
}

File? _resolveWorkspaceFile(WorkingDirectory workspace, String rawPath) {
  final workspacePath = path.normalize(workspace.root.absolute.path);
  final currentPath = path.normalize(workspace.current.absolute.path);
  final targetPath = path.isAbsolute(rawPath)
      ? path.normalize(rawPath)
      : path.normalize(path.join(currentPath, rawPath));
  final relative = path.relative(targetPath, from: workspacePath);
  if (relative == '..' || relative.startsWith('..${path.separator}')) {
    return null;
  }
  return File(targetPath);
}

Directory? _resolveListDirectory(WorkingDirectory workspace, String? rawPath) {
  final workspacePath = path.normalize(workspace.root.absolute.path);
  final currentPath = path.normalize(workspace.current.absolute.path);
  final targetPath = rawPath == null || rawPath.isEmpty
      ? currentPath
      : path.isAbsolute(rawPath)
      ? path.normalize(rawPath)
      : path.normalize(path.join(currentPath, rawPath));

  final relative = path.relative(targetPath, from: workspacePath);
  if (relative == '..' || relative.startsWith('..${path.separator}')) {
    return null;
  }

  return Directory(targetPath);
}

// Tool writeTool() => Tool(
//       name: 'write',
//       description:
//           'Overwrites a text file inside the granted workspace with the given '
//           'content. Path is relative to the workspace root, or a full '
//           'content:// URI.',
//       parameters: {
//         'type': 'object',
//         'properties': {
//           'path': {'type': 'string'},
//           'content': {'type': 'string'},
//         },
//         'required': ['path', 'content'],
//       },
//       handler: (call) async {
//         final uri =
//             await Workspace.instance.resolve(call.arguments['path'] as String);
//         final content = call.arguments['content'] as String;
//         final data = utf8.encode(content);
//         await Workspace.instance.saf.withFileDescriptor(uri, 'w', (fd) async {
//           await File(fd.path).writeAsBytes(data, flush: true);
//           return null;
//         });
//         return ToolCallResult(
//           id: call.id,
//           ok: true,
//           output: 'Wrote ${data.length} bytes to $uri',
//           filesChanged: [FileChange(path: uri)],
//         );
//       },
//     );

const kMaxFindResults = 500;

const kDefaultFindLimit = 25;

Tool findTool(WorkingDirectory workspace) => Tool(
  name: 'find',
  description:
      'Recursively finds files or directories below a path. Use path like '
      '"." and a shell-style glob pattern like "*.pdf". The type flag is '
      '"file" by default or "dir" for directories. Relative paths start at '
      'the current working directory; absolute paths must stay inside the '
      'granted workspace root. Returns up to limit matches starting at '
      'offset, plus the total count in the header; use count_only=true to '
      'get just the number. Only raise limit when the task requires '
      'exhaustive enumeration.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'Optional directory or file to search below; use "." for the current '
            'working directory.'
            'default: "."',
        'default': '.',
      },
      'pattern': {
        'type': 'string',
        'description':
            'Name pattern: shell-style glob ("*.pdf", "report-??.txt") or '
            'regular expression ("\\.pdf\$"). Both are accepted.',
      },
      'type': {
        'type': 'string',
        'enum': ['file', 'dir'],
        'description': 'Match regular files or directories. Defaults to file.',
        'default': 'file',
      },
      'max_depth': {
        'type': 'integer',
        'description':
            'Maximum search depth relative to path. 0 checks only path, 1 '
            'checks its direct children, and so on. Defaults to 3.',
        'default': 3,
        'minimum': 0,
      },
      'count_only': {
        'type': 'boolean',
        'description':
            'When true, returns only the total match count without listing '
            'paths. Cheapest way to answer "how many" questions.',
        'default': false,
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of matches to return per call.',
        'default': kDefaultFindLimit,
        'minimum': 1,
      },
      'offset': {
        'type': 'integer',
        'description':
            'Number of matches to skip before returning results. Use the '
            'offset from the continuation hint in the output for the next '
            'page.',
        'default': 0,
        'minimum': 0,
      },
      'grep': {
        'type': 'string',
        'description':
            'Optional case-insensitive regular expression or substring filter to '
            'filter returned file/directory paths.',
      },
    },
    'required': ['path', 'pattern'],
  },
  handler: (call) async {
    final rawPath = (call.arguments['path'] as String?)?.trim() ?? '.';
    final pattern = (call.arguments['pattern'] as String?)?.trim();
    final type = (call.arguments['type'] as String?) ?? 'file';
    final maxDepth = (call.arguments['max_depth'] as num?)?.toInt() ?? 3;
    final countOnly = (call.arguments['count_only'] as bool?) ?? false;
    final limit = min((call.arguments['limit'] as num?)?.toInt() ?? kDefaultFindLimit, kMaxFindResults);
    final offset = (call.arguments['offset'] as num?)?.toInt() ?? 0;

    if (offset < 0) {
      return ToolCallResult.failure(
        call.id,
        'Invalid offset: offset must be >= 0.',
      );
    }
    if (limit <= 0) {
      return ToolCallResult.failure(
        call.id,
        'Invalid limit: limit must be > 0.',
      );
    }

    if (pattern == null || pattern.isEmpty) {
      return ToolCallResult.failure(
        call.id,
        'Invalid pattern: pattern is required.',
      );
    }
    if (type != 'file' && type != 'dir') {
      return ToolCallResult.failure(
        call.id,
        'Invalid type "$type": expected "file" or "dir".',
      );
    }
    if (maxDepth < 0 || maxDepth > 32) {
      return ToolCallResult.failure(
        call.id,
        'Invalid max_depth "$maxDepth": expected a value from 0 to 32.',
      );
    }

    final target = _resolveListDirectory(workspace, rawPath);
    if (target == null) {
      return ToolCallResult.failure(
        call.id,
        'Invalid path: it must stay inside the workspace root.',
      );
    }

    final matcher = _findMatcher(pattern);
    final matchSubpath = pattern.contains('/');
    final results = <String>[];
    final skippedPaths = <String>[];
    try {
      final entityType = await FileSystemEntity.type(target.path);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolCallResult.failure(
          call.id,
          'Path not found: ${target.path}',
        );
      }

      await _collectFindMatches(
        target: target,
        currentDirectory: workspace.current,
        matcher: matcher,
        matchSubpath: matchSubpath,
        type: type,
        maxDepth: maxDepth,
        results: results,
        skippedPaths: skippedPaths,
      );
    } catch (e) {
      return ToolCallResult.failure(
        call.id,
        'Failed to find below "${target.path}": $e',
      );
    }

    // Same deterministic-order requirement as list: sort before windowing
    // so offset pages are stable between calls.
    results.sort();

    final total = results.length;
    final hitCeiling = total >= kMaxFindResults;
    final header = [
      'current directory: ${workspace.current.path}',
      'find path: ${target.path}',
      'type: $type',
      'pattern: $pattern',
      'max depth: $maxDepth',
      'found $total${hitCeiling ? '+' : ''} match(es)',
      if (skippedPaths.isNotEmpty)
        'skipped ${skippedPaths.length} inaccessible path(s); results may be partial',
    ];

    if (countOnly) {
      return ToolCallResult(
        id: call.id,
        ok: true,
        output: [...header, 'count only; no paths listed'].join('\n'),
      );
    }

    final start = min(offset, total);
    final end = min(start + limit, total);
    final window = results.sublist(start, end);

    var outputEntries = window;
    final grep = (call.arguments['grep'] as String?)?.trim();
    if (grep != null && grep.isNotEmpty) {
      final filteredText = GrepFilter.filter(window.join('\n'), grep);
      outputEntries = filteredText.split('\n');
    }

    return ToolCallResult(
      id: call.id,
      ok: true,
      output: [
        ...header,
        if (window.isEmpty && total > 0)
          'offset $offset is beyond the last match ($total total); use offset < $total'
        else ...[
          'showing ${start + 1}–$end of $total',
          if (end < total) 'use offset=$end for the next page',
        ],
        ...outputEntries,
      ].join('\n'),
    );
  },
);

Future<void> _collectFindMatches({
  required FileSystemEntity target,
  required Directory currentDirectory,
  required RegExp matcher,
  required bool matchSubpath,
  required String type,
  required int maxDepth,
  required List<String> results,
  required List<String> skippedPaths,
}) async {
  if (results.length >= kMaxFindResults) return;

  late final FileStat targetStat;
  try {
    targetStat = await target.stat();
  } on FileSystemException {
    skippedPaths.add(target.path);
    return;
  }
  final isDir = targetStat.type == FileSystemEntityType.directory;
  final isFile = targetStat.type == FileSystemEntityType.file;

  final targetMatches = type == 'file' ? isFile : isDir;
  final relativePath = path.relative(target.path, from: currentDirectory.path);
  final targetName = matchSubpath
      ? path.relative(target.path, from: target.path)
      : path.basename(target.path);
  if (targetMatches && matcher.hasMatch(targetName)) {
    results.add(relativePath);
  }

  if (!isDir || maxDepth == 0) {
    return;
  }

  await _walkFindDirectory(
    rootTarget: Directory(target.path),
    directory: Directory(target.path),
    currentDirectory: currentDirectory,
    matcher: matcher,
    matchSubpath: matchSubpath,
    type: type,
    depth: 0,
    maxDepth: maxDepth,
    results: results,
    skippedPaths: skippedPaths,
  );
}

Future<void> _walkFindDirectory({
  required Directory rootTarget,
  required Directory directory,
  required Directory currentDirectory,
  required RegExp matcher,
  required bool matchSubpath,
  required String type,
  required int depth,
  required int maxDepth,
  required List<String> results,
  required List<String> skippedPaths,
}) async {
  if (depth >= maxDepth || results.length >= kMaxFindResults) return;

  try {
    await for (final entity in directory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (results.length >= kMaxFindResults) return;

      final childDepth = depth + 1;
      bool isDir = false;
      bool isFile = false;
      if (entity is Directory) {
        isDir = true;
      } else if (entity is File) {
        isFile = true;
      } else {
        try {
          final stat = await entity.stat();
          isDir = stat.type == FileSystemEntityType.directory;
          isFile = stat.type == FileSystemEntityType.file;
        } on FileSystemException {
          skippedPaths.add(entity.path);
          continue;
        }
      }

      final isMatchType = type == 'file' ? isFile : isDir;
      final relativePath = path.relative(entity.path, from: currentDirectory.path);
      final testName = matchSubpath
          ? path.relative(entity.path, from: rootTarget.path)
          : path.basename(entity.path);
      if (isMatchType && matcher.hasMatch(testName)) {
        results.add(relativePath);
      }

      if (isDir && childDepth < maxDepth) {
        await _walkFindDirectory(
          rootTarget: rootTarget,
          directory: Directory(entity.path),
          currentDirectory: currentDirectory,
          matcher: matcher,
          matchSubpath: matchSubpath,
          type: type,
          depth: childDepth,
          maxDepth: maxDepth,
          results: results,
          skippedPaths: skippedPaths,
        );
      }
    }
  } on FileSystemException {
    // Shared storage often contains provider-owned directories that can be
    // stat'ed but not listed. A blocked branch should not fail the search.
    skippedPaths.add(directory.path);
  }
}

Tool cdTool(WorkingDirectory workspace) => Tool(
  name: 'cd',
  description:
      'Changes the current working directory inside the granted workspace. '
      'Relative paths are resolved from the current working directory. Use '
      '".." to move to the parent directory, but never outside the granted '
      'workspace root.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative or absolute directory path.',
      },
    },
    'required': ['path'],
  },
  handler: (call) async {
    final rawPath = (call.arguments['path'] as String?)?.trim();
    if (rawPath == null || rawPath.isEmpty) {
      return ToolCallResult.failure(call.id, 'Invalid path: path is required.');
    }

    final target = _resolveListDirectory(workspace, rawPath);
    if (target == null) {
      return ToolCallResult.failure(
        call.id,
        'Invalid path: it must stay inside the workspace root.',
      );
    }

    try {
      if (!await target.exists()) {
        return ToolCallResult.failure(
          call.id,
          'Directory not found: ${target.path}',
        );
      }
      final stat = await target.stat();
      if (stat.type != FileSystemEntityType.directory) {
        return ToolCallResult.failure(
          call.id,
          'Not a directory: ${target.path}',
        );
      }

      final previous = workspace.current.path;
      workspace.current = Directory(target.absolute.path);
      return ToolCallResult(
        id: call.id,
        ok: true,
        output:
            'Changed current directory from $previous to ${workspace.current.path}',
      );
    } catch (e) {
      return ToolCallResult.failure(
        call.id,
        'Failed to change directory to "${target.path}": $e',
      );
    }
  },
);

RegExp _globRegExp(String pattern) {
  final buffer = StringBuffer('^');
  for (var index = 0; index < pattern.length; index++) {
    final character = pattern[index];
    switch (character) {
      case '*':
        buffer.write('.*');
      case '?':
        buffer.write('.');
      default:
        buffer.write(RegExp.escape(character));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), caseSensitive: false);
}

/// Builds the find matcher: the glob translation of [pattern], plus a raw
/// regex fallback when the pattern contains regex metacharacters.
///
/// Models mix both conventions constantly — `*.pdf` (glob) and `\.pdf$`
/// (regex) — and the sibling `list` action even documents its pattern as a
/// RegExp. A glob-only matcher silently returns 0 matches for a valid regex
/// like `\.pdf$` (every char gets escaped literally), wasting a whole agent
/// turn. Matching either interpretation keeps globs working as before and
/// rescues regex-style patterns.
RegExp _findMatcher(String pattern) {
  final glob = _globRegExp(pattern);
  // Strong regex signals only (\ ^ $ [ ( | {) — plain dots stay glob-only
  // so "report??.txt"-style names don't pick up surprising regex matches.
  if (!RegExp(r'[\\^$[()|{]').hasMatch(pattern)) return glob;
  try {
    final regex = RegExp(pattern, caseSensitive: false);
    return RegExp(
      '(${glob.pattern})|(${regex.pattern})',
      caseSensitive: false,
    );
  } catch (_) {
    return glob; // not a valid regex — glob behavior unchanged
  }
}

// Tool grepTool() => Tool(
//       name: 'grep',
//       description:
//           'Searches file contents inside the granted workspace for a RegExp. '
//           'Only text files are searched; binary/large files are skipped. '
//           'Returns "relativePath:lineNumber: line".',
//       parameters: {
//         'type': 'object',
//         'properties': {
//           'pattern': {
//             'type': 'string',
//             'description': 'RegExp to search for in file contents',
//           },
//         },
//         'required': ['pattern'],
//       },
//       handler: (call) async {
//         final root = Workspace.instance.grantedUri;
//         if (root == null) return ToolCallResult.failure(call.id, 'No workspace granted');
//         final re = RegExp(call.arguments['pattern'] as String);
//         final matches = <String>[];
//         final saf = Workspace.instance.saf;

//         await for (final entry in saf.walk(root)) {
//           if (entry.file.isDir) continue;
//           if (entry.file.length > kMaxGrepFileBytes) continue;
//           if (matches.length >= kMaxGrepMatches) break;
//           try {
//             final bytes = await saf.readFileBytes(entry.file.uri);
//             final text = utf8.decode(bytes, allowMalformed: true);
//             for (final line in text.split('\n')) {
//               if (matches.length >= kMaxGrepMatches) break;
//               if (re.hasMatch(line)) {
//                 final lineNo = text.split('\n').indexOf(line) + 1;
//                 matches.add('${entry.relativePath}:$lineNo: $line');
//               }
//             }
//           } catch (_) {}
//         }

//         return ToolCallResult(
//           id: call.id,
//           ok: true,
//           output: matches.isEmpty
//               ? 'No matches'
//               : '${matches.length} match(es):\n${matches.join('\n')}',
//         );
//       },
//     );
