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

  /// Whether execution must pass an application-level validation or approval
  /// step before the handler is allowed to run.
  ///
  /// This is deliberately internal metadata and is not sent to the model as
  /// part of the function schema. Read-only tools can leave it false;
  /// mutation tools should set it true when they are added.
  final bool requiresValidation;

  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
    this.requiresValidation = false,
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
