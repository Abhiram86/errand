import '../agent/tool.dart';
import 'file_tools.dart';
import '../types/tool.dart';

/// Public workspace router. The concrete handlers remain in file_tools.dart
/// for now, while the model sees one navigation-oriented tool.
Tool workspaceTool(WorkingDirectory workspace) {
  final handlers = <String, Tool>{
    'list': listTool(workspace),
    'find': findTool(workspace),
    'cd': cdTool(workspace),
  };

  return Tool(
    name: 'workspace',
    description:
        'Browse and navigate workspace directories. Actions: "list" (show folder entries), '
        '"find" (search files/folders by pattern), "cd" (change working directory), '
        'or "pwd" (get current directory). Do NOT use this tool to read file contents; '
        'use the "read" tool instead.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['pwd', 'cd', 'list', 'find'],
          'description': 'Workspace action to perform.',
        },
        'path': {
          'type': 'string',
          'description':
              'Path for cd/list/find. Relative paths use the current '
              'directory; use "." for the current directory.',
        },
        'pattern': {
          'type': 'string',
          'description':
              'Pattern for find or regular-expression filter for list.',
        },
        'type': {
          'type': 'string',
          'enum': ['file', 'dir'],
          'description': 'find match type. Defaults to file.',
          'default': 'file',
        },
        'max_depth': {
          'type': 'integer',
          'description': 'find depth limit. Defaults to 3.',
          'default': 3,
          'minimum': 0,
        },
        'grep': {
          'type': 'string',
          'description':
              'Optional case-insensitive regular expression or substring filter '
              'to filter the list/find output lines.',
        },
        'sort_by': {
          'type': 'string',
          'enum': ['name', 'modified', 'size'],
          'description':
              'Optional field to sort entries by: "name" (default), "modified", or "size".',
          'default': 'name',
        },
        'sort_order': {
          'type': 'string',
          'enum': ['asc', 'desc'],
          'description':
              'Optional sort direction: "asc" or "desc". Defaults to "desc" for modified, "asc" otherwise.',
        },
        'metadata': {
          'type': 'boolean',
          'description':
              'Whether to include file metadata (type, size, modified timestamp). Defaults to true.',
          'default': true,
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      final action = (call.arguments['action'] as String?)?.trim();
      if (action == null || action.isEmpty) {
        return ToolCallResult.failure(
          call.id,
          'Invalid action: action is required.',
        );
      }

      if (action == 'pwd') {
        return ToolCallResult(
          id: call.id,
          ok: true,
          output:
              'Current working directory: ${workspace.current.path}\n'
              'Workspace root: ${workspace.root.path}',
        );
      }

      final delegated = handlers[action];
      if (delegated == null) {
        return ToolCallResult.failure(
          call.id,
          'Unknown workspace action "$action". Expected pwd, cd, list, or find.',
        );
      }

      return delegated.handler(
        ToolCall(id: call.id, name: action, arguments: call.arguments),
      );
    },
  );
}
