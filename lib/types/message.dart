class ToolInvocation {
  final String name;
  final Map<String, dynamic> args;

  const ToolInvocation({required this.name, required this.args});
}

sealed class Message {
  final String id;
  final String text;

  const Message({required this.id, required this.text});
}

class UserMessage extends Message {
  final List<String> attachedUris;

  const UserMessage({
    required super.id,
    required super.text,
    this.attachedUris = const [],
  });
}

class AssistantMessage extends Message {
  final String? model;
  final String? provider;

  const AssistantMessage({
    required super.id,
    required super.text,
    this.model,
    this.provider,
  });
}

class ToolMessage extends Message {
  final ToolInvocation tool;
  final String result;
  final String? reasoning;
  final List<Map<String, dynamic>> reasoningDetails;

  const ToolMessage({
    required super.id,
    required super.text,
    required this.tool,
    required this.result,
    this.reasoning,
    this.reasoningDetails = const [],
  });
}

class ErrorMessage extends Message {
  final String error;

  const ErrorMessage({
    required super.id,
    required super.text,
    required this.error,
  });
}
