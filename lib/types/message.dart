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
  const UserMessage({required super.id, required super.text});
}

class AssistantMessage extends Message {
  const AssistantMessage({required super.id, required super.text});
}

class ToolMessage extends Message {
  final ToolInvocation tool;
  final String result;

  const ToolMessage({
    required super.id,
    required super.text,
    required this.tool,
    required this.result,
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
