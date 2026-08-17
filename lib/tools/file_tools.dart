import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../agent/tool.dart';
// import '../services/workspace.dart';
import '../types/tool.dart';
import '../internal/document_reading/document_reader.dart';

import 'package:path/path.dart' as path;

const kMaxReadBytes = 512 * 1024;
const kMaxGrepFileBytes = 256 * 1024;
const kMaxGrepMatches = 200;

Tool readTool() => Tool(
  name: 'read',
  description:
      'Reads a chunk of a file inside the granted workspace. Supports text '
      'files plus PDF, DOCX, XLSX, and PPTX extraction. For text files, '
      'offset and length are byte-based. For structured files, offset is a '
      'logical page/slide/section offset and length is a character budget; '
      'structured pages overlap between reads. Path may be relative to the '
      'workspace root or a full content:// URI.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path or content:// URI of the file',
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
    },
    'required': ['path'],
  },
  handler: (call) async {
    final rawPath = call.arguments['path'] as String;
    final offset = (call.arguments['offset'] as int?) ?? 0;
    final length = (call.arguments['length'] as int?) ?? 512;

    // Validate arguments.
    if (rawPath.trim().isEmpty) {
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

    // Resolve the file, including fallback path.
    File? file;

    final candidates = <String>[
      rawPath,
      if (!rawPath.startsWith('/')) '/storage/emulated/0/$rawPath',
      if (rawPath.startsWith('/')) '/storage/emulated/0$rawPath',
    ];

    for (final candidate in candidates) {
      final candidateFile = File(candidate);

      if (await candidateFile.exists()) {
        file = candidateFile;
        break;
      }
    }

    if (file == null) {
      return ToolCallResult.failure(
        call.id,
        'File not found. Tried: ${candidates.join(', ')}',
      );
    }

    try {
      final structured = await readStructuredFile(
        file,
        offset: offset,
        length: length,
      );
      if (structured != null) {
        return ToolCallResult(
          id: call.id,
          ok: true,
          output: structured.toToolOutput(file.path),
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

Tool listTool(Directory workspace) => Tool(
  name: 'list',
  description:
      'Lists files and directories. Without path, lists the current directory. '
      'A relative path is resolved from the current directory; an absolute '
      'path may be used for another location inside the workspace. If a '
      'pattern is provided, only matching paths are returned.',
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
    },
  },
  handler: (call) async {
    final rawPath = (call.arguments['path'] as String?)?.trim();
    final pattern = call.arguments['pattern'] as String?;

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
    results.add("current directory: ${workspace.path}");
    results.add("temp");

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
        final relativePath = path.relative(entity.path, from: workspace.path);

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

    results[1] = "found ${results.length - 2} file(s)";

    return ToolCallResult(id: call.id, ok: true, output: results.join('\n'));
  },
);

Directory? _resolveListDirectory(Directory workspace, String? rawPath) {
  final workspacePath = path.normalize(workspace.absolute.path);
  final targetPath = rawPath == null || rawPath.isEmpty
      ? workspacePath
      : path.isAbsolute(rawPath)
      ? path.normalize(rawPath)
      : path.normalize(path.join(workspacePath, rawPath));

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

// Tool findTool() => Tool(
//       name: 'find',
//       description:
//           'Lists files inside the granted workspace whose name matches a '
//           'substring or RegExp pattern. Returns relative paths.',
//       parameters: {
//         'type': 'object',
//         'properties': {
//           'pattern': {
//             'type': 'string',
//             'description': 'Substring or RegExp to match against file names',
//           },
//         },
//         'required': ['pattern'],
//       },
//       handler: (call) async {
//         final root = Workspace.instance.grantedUri;
//         if (root == null) return ToolCallResult.failure(call.id, 'No workspace granted');
//         final pattern = call.arguments['pattern'] as String;
//         final re = RegExp(pattern);
//         final results = <String>[];
//         await for (final entry in Workspace.instance.saf.walk(root)) {
//           if (entry.file.isDir) continue;
//           if (re.hasMatch(entry.file.name)) {
//             results.add(entry.relativePath);
//           }
//         }
//         return ToolCallResult(
//           id: call.id,
//           ok: true,
//           output: results.isEmpty
//               ? 'No matches'
//               : '${results.length} match(es):\n${results.join('\n')}',
//         );
//       },
//     );

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
