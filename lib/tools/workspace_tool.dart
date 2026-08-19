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
        'Inspects and changes the current workspace directory. Use action '
        '"pwd" to see the current directory, "cd" to change it, "list" to '
        'list immediate entries, or "find" to recursively search files and '
        'directories. The current directory is shared by read and workspace '
        'actions.',
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
