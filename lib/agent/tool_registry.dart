import 'dart:io';

import 'tool.dart';
import '../services/a11y_service.dart';
import '../tools/act_tool.dart';
import '../tools/attached_files_tool.dart';
import '../tools/file_tools.dart';
import '../tools/workspace_tool.dart';
import '../tools/intent_tool.dart';
import '../tools/screen_tool.dart';
import '../tools/web_tools.dart';
import '../types/tool.dart';

/// Registry of available tools, keyed by name, plus a safe `execute` that
/// turns any `ToolCall` into a `ToolCallResult`.
class ToolRegistry {
  final Map<String, Tool> _tools = {};

  ToolRegistry(List<Tool> tools) {
    for (final tool in tools) {
      _tools[tool.name] = tool;
    }
  }

  factory ToolRegistry.defaults({
    required Directory currentDir,
    WorkingDirectory? workingDirectory,
    bool Function(String modality)? supportsInput,
    List<String> Function()? getAttachedFiles,
    A11yService? a11yService,
  }) {
    final directory = workingDirectory ?? WorkingDirectory(currentDir);
    return ToolRegistry([
      readTool(
        directory,
        supportsInput: supportsInput,
        getAttachedFiles: getAttachedFiles,
      ),
      workspaceTool(directory),
      webSearchTavilyTool(),
      webFetchTool(),
      intentTool(a11yService: a11yService),
      screenTool(service: a11yService),
      actTool(service: a11yService),
      attachedFilesTool(
        getAttachedFiles: getAttachedFiles ?? () => const [],
      ),
    ]);
  }

  List<Tool> get all => _tools.values.toList();

  /// Releases resources held by registered tools (e.g. cached open documents).
  void dispose() {
    for (final tool in _tools.values) {
      tool.dispose();
    }
  }

  Future<ToolCallResult> execute(ToolCall call) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return ToolCallResult.failure(call.id, 'Unknown tool: ${call.name}');
    }
    try {
      return await tool.handler(call);
    } catch (e) {
      return ToolCallResult.failure(call.id, '$e', type: 'handler_error');
    }
  }
}
