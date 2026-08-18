import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../agent/tool.dart';
// import '../services/workspace.dart';
import '../types/tool.dart';
import '../internal/document_reading/document_reader.dart';

import 'package:path/path.dart' as path;

const kMaxReadBytes = 512 * 1024;

class WorkingDirectory {
  final Directory root;
  Directory current;

  WorkingDirectory(this.root, {Directory? current}) : current = current ?? root;
}

Tool readTool(WorkingDirectory workspace) {
  final structuredDocuments = <String, Future<LogicalDocument?>>{};

  return Tool(
    name: 'read',
    description:
        'Reads a chunk of a file inside the granted workspace. Supports text '
        'files plus PDF, DOCX, XLSX, and PPTX extraction. For text files, '
        'offset and length are byte-based. For structured files, offset is a '
        'logical page/slide/section offset and length is a character budget; '
        'structured pages overlap between reads. Path is relative to the '
        'workspace or an absolute path inside it.',
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

      if (length > kMaxReadBytes) {
        return ToolCallResult.failure(
          call.id,
          'Invalid length: maximum readable range is $kMaxReadBytes bytes.',
        );
      }

      final file = _resolveWorkspaceFile(workspace, rawPath);
      if (file == null || !await file.exists()) {
        return ToolCallResult.failure(
          call.id,
          'File not found or outside the workspace: $rawPath',
        );
      }

      try {
        final document = await structuredDocuments.putIfAbsent(
          file.path,
          () => readStructuredDocument(file),
        );
        final structured = document?.read(offset: offset, length: length);
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
}

Tool listTool(WorkingDirectory workspace) => Tool(
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

    final header = [
      'current directory: ${target.path}',
      'found ${results.length} file(s)',
    ];
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: [...header, ...results].join('\n'),
    );
  },
);

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

Tool findTool(WorkingDirectory workspace) => Tool(
  name: 'find',
  description:
      'Recursively finds files or directories below a path. Use path like '
      '"." and a shell-style glob pattern like "*.pdf". The type flag is '
      '"file" by default or "dir" for directories. Relative paths start at '
      'the current working directory; absolute paths must stay inside the '
      'granted workspace root.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'Directory or file to search below; use "." for the current '
            'working directory.',
      },
      'pattern': {
        'type': 'string',
        'description':
            'Shell-style name pattern, for example "*.pdf" or "report-??.txt".',
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
    },
    'required': ['path', 'pattern'],
  },
  handler: (call) async {
    final rawPath = (call.arguments['path'] as String?)?.trim();
    final pattern = (call.arguments['pattern'] as String?)?.trim();
    final type = (call.arguments['type'] as String?) ?? 'file';
    final maxDepth = (call.arguments['max_depth'] as int?) ?? 3;

    if (rawPath == null || rawPath.isEmpty) {
      return ToolCallResult.failure(call.id, 'Invalid path: path is required.');
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

    final matcher = _globRegExp(pattern);
    final results = <String>[];
    try {
      if (!await target.exists()) {
        return ToolCallResult.failure(
          call.id,
          'Path not found: ${target.path}',
        );
      }

      await _collectFindMatches(
        target: target,
        currentDirectory: workspace.current,
        matcher: matcher,
        type: type,
        maxDepth: maxDepth,
        results: results,
      );
    } catch (e) {
      return ToolCallResult.failure(
        call.id,
        'Failed to find below "${target.path}": $e',
      );
    }

    final truncated = results.length >= kMaxFindResults;
    final header = [
      'current directory: ${workspace.current.path}',
      'find path: ${target.path}',
      'type: $type',
      'pattern: $pattern',
      'max depth: $maxDepth',
      'found ${results.length}${truncated ? '+' : ''} match(es)',
    ];
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: [...header, ...results].join('\n'),
    );
  },
);

Future<void> _collectFindMatches({
  required FileSystemEntity target,
  required Directory currentDirectory,
  required RegExp matcher,
  required String type,
  required int maxDepth,
  required List<String> results,
}) async {
  if (results.length >= kMaxFindResults) return;

  final targetStat = await target.stat();
  final targetMatches = type == 'file'
      ? targetStat.type == FileSystemEntityType.file
      : targetStat.type == FileSystemEntityType.directory;
  if (targetMatches && matcher.hasMatch(path.basename(target.path))) {
    results.add(path.relative(target.path, from: currentDirectory.path));
  }

  if (targetStat.type != FileSystemEntityType.directory || maxDepth == 0) {
    return;
  }

  await _walkFindDirectory(
    directory: Directory(target.path),
    currentDirectory: currentDirectory,
    matcher: matcher,
    type: type,
    depth: 0,
    maxDepth: maxDepth,
    results: results,
  );
}

Future<void> _walkFindDirectory({
  required Directory directory,
  required Directory currentDirectory,
  required RegExp matcher,
  required String type,
  required int depth,
  required int maxDepth,
  required List<String> results,
}) async {
  if (depth >= maxDepth || results.length >= kMaxFindResults) return;

  await for (final entity in directory.list(
    recursive: false,
    followLinks: false,
  )) {
    if (results.length >= kMaxFindResults) return;

    final childDepth = depth + 1;
    final stat = await entity.stat();
    final isMatchType = type == 'file'
        ? stat.type == FileSystemEntityType.file
        : stat.type == FileSystemEntityType.directory;
    if (isMatchType && matcher.hasMatch(path.basename(entity.path))) {
      results.add(path.relative(entity.path, from: currentDirectory.path));
    }

    if (stat.type == FileSystemEntityType.directory && childDepth < maxDepth) {
      await _walkFindDirectory(
        directory: Directory(entity.path),
        currentDirectory: currentDirectory,
        matcher: matcher,
        type: type,
        depth: childDepth,
        maxDepth: maxDepth,
        results: results,
      );
    }
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
