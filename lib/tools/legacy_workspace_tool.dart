import '../agent/tool.dart';
import 'file_tools.dart';
import '../types/tool.dart';

/// Legacy workspace router kept for backward compatibility and test suites.
/// Active agent loops use [bashTool] for directory inspection and navigation.
Tool legacyWorkspaceTool(WorkingDirectory workspace) {
  // list and find are retired from the model schema in favor of bash (ls, find),
  // but kept in handlers for backward compatibility with existing conversations/tests.
  final handlers = <String, Tool>{
    'list': legacyListTool(workspace),
    'find': legacyFindTool(workspace),
    'cd': legacyCdTool(workspace),
  };

  return Tool(
    name: 'workspace',
    description:
        'Manage working directory navigation. Actions: "cd" (change working directory) '
        'or "pwd" (get current directory). For browsing, listing, or searching files and '
        'folders, use the "bash" tool (e.g. ls, find, grep). Do NOT use this tool to '
        'read file contents; use the "read" tool instead.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['pwd', 'cd'],
          'description': 'Workspace action to perform: "pwd" or "cd".',
        },
        'path': {
          'type': 'string',
          'description':
              'Target directory path for cd. Relative paths use the current '
              'directory; use "." for the current directory.',
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

@Deprecated('Use legacyWorkspaceTool instead')
Tool workspaceTool(WorkingDirectory workspace) => legacyWorkspaceTool(workspace);
