import 'package:path/path.dart' as path;

import '../agent/tool.dart';
import '../types/tool.dart';

Tool attachedFilesTool({
  required List<String> Function() getAttachedFiles,
}) {
  return Tool(
    name: 'attached_files',
    description:
        'Lists files the user attached via the + button in this conversation. '
        'Returns count and file names. Use read to open any of them — the '
        'path is the full URI shown here. Call this when the user refers to '
        '"the attached file" or you need to know what is available.',
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
