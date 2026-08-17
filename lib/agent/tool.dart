import 'dart:convert';

import '../types/tool.dart';

/// A tool handler: takes a parsed `ToolCall` and returns a `ToolCallResult`.
typedef ToolHandler = Future<ToolCallResult> Function(ToolCall call);

/// OpenAI-function-schema metadata for one tool, used to advertise tools to
/// the LLM. The `handler` is the real implementation.
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final ToolHandler handler;

  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
  });

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// A tool call as emitted by the LLM (`tool_calls[].function`).
class ToolCall {
  final String id;
  final String name;
  final ToolArguments arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {
      'name': name,
      // OpenAI-compatible APIs require function arguments to be a JSON
      // string, even though the parsed ToolCall stores them as a map.
      'arguments': jsonEncode(arguments),
    },
  };
}
