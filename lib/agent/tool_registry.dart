import 'dart:io';

import 'tool.dart';
import '../tools/file_tools.dart';
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

  factory ToolRegistry.defaults({required Directory currentDir}) =>
      ToolRegistry([readTool(), listTool(currentDir)]);

  List<Tool> get all => _tools.values.toList();

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
