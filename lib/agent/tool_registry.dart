import 'dart:io';

import '../llm/llm_client.dart';
import '../services/browser_service.dart';
import '../services/memory_service.dart';
import '../services/shell_service.dart';
import '../services/tool_output_file_service.dart';
import '../tools/act_tool.dart';
import '../tools/attached_files_tool.dart';
import '../tools/bash_tool.dart';
import '../tools/browser_tool.dart';
import '../tools/file_tools.dart';
import '../tools/intent_tool.dart';
import '../tools/memory_tool.dart';
import '../tools/screen_tool.dart';
import '../tools/web_tools.dart';
import '../types/tool.dart';
import 'tool.dart';

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
    bool hasTavilyKey = false,
    bool enableA11yTools = true,
    ShellService? shellService,
    CancelToken Function()? getCancelToken,
    MemoryService? memoryService,
    String? currentConversationId,
    BrowserService? browserService,
    Future<ConfirmationDecision> Function({
      required String title,
      required String command,
      String? reason,
    })? onConfirmCommand,
    bool Function()? isSessionTrusted,
  }) {
    final directory = workingDirectory ?? WorkingDirectory(currentDir);
    return ToolRegistry([
      readTool(
        directory,
        supportsInput: supportsInput,
        getAttachedFiles: getAttachedFiles,
      ),
      bashTool(
        workingDirectory: directory,
        shellService: shellService,
        getCancelToken: getCancelToken,
        onConfirmCommand: onConfirmCommand,
        isSessionTrusted: isSessionTrusted,
      ),
      webSearchTavilyTool(),
      webFetchTool(),
      intentTool(),
      memoryTool(
        memoryService: memoryService,
        currentConversationId: currentConversationId,
      ),
      browserTool(
        browserService: browserService,
        supportsInput: supportsInput,
      ),
      if (enableA11yTools) ...[
        screenTool(
          supportsInput: supportsInput,
        ),
        actTool(),
      ],
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
    var tool = _tools[call.name];
    if (tool == null &&
        (call.name.startsWith('memory.') || call.name.startsWith('memory_'))) {
      tool = _tools['memory'];
    }
    if (tool == null &&
        (call.name.startsWith('browser.') || call.name.startsWith('browser_'))) {
      tool = _tools['browser'];
    }
    if (tool == null &&
        (call.name.startsWith('extract_text.') ||
            call.name.startsWith('extract_text_') ||
            call.name == 'extract_text')) {
      tool = _tools['extract_text'] ?? _tools['browser'];
    }
    if (tool == null &&
        (call.name.startsWith('screen_act.') ||
            call.name.startsWith('screen_act_') ||
            call.name.startsWith('act.') ||
            call.name.startsWith('act_') ||
            call.name == 'act' ||
            call.name == 'screen_act')) {
      tool = _tools['screen_act'] ?? _tools['act'];
    }
    if (tool == null) {
      return ToolCallResult.failure(call.id, 'Unknown tool: ${call.name}');
    }
    try {
      final result = await tool.handler(call);
      return await ToolOutputFileService.instance.maybeSpillResult(
        result,
        callId: call.id,
      );
    } catch (e) {
      return ToolCallResult.failure(call.id, '$e', type: 'handler_error');
    }
  }
}

