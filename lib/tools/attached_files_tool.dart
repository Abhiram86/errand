import 'package:path/path.dart' as path;

import '../agent/tool.dart';
import '../types/tool.dart';

Tool attachedFilesTool({
  required List<String> Function() getAttachedFiles,
}) {
  return Tool(
    name: 'attached_files',
    description:
        'Lists files the user attached or uploaded in this conversation. '
        'Returns count, file names, and absolute URIs for each file. '
        'Use read to open any of them. Call this whenever the user refers to '
        '"this file", "the attached file", "the uploaded document", or asks '
        'to inspect or summarize something without specifying a path.',
    parameters: {
      'type': 'object',
      'properties': {},
      'required': [],
    },
    handler: (call) async {
      final uris = getAttachedFiles();
      if (uris.isEmpty) {
        return ToolCallResult(
          id: call.id,
          ok: true,
          output: 'No files attached in this conversation.',
        );
      }
      final lines = <String>[
        'Attached files: ${uris.length}',
        for (var i = 0; i < uris.length; i++)
          '${i + 1}. ${path.basename(uris[i])} — ${uris[i]}',
      ];
      return ToolCallResult(
        id: call.id,
        ok: true,
        output: lines.join('\n'),
      );
    },
  );
}
