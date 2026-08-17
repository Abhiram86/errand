/// Message model — mirrors `src/types/message.ts` from the Expo app.
///
/// TypeScript models this as a discriminated union on `role`; Dart has no
/// unions, so the same idea is expressed with a `sealed` base class plus one
/// subclass per role. Always `switch` on the type (or on `role`) to handle a
/// message — the compiler will warn if a case is missing.
library;

/// The `role` discriminator, matching the TS string-literal roles.
enum MessageRole { user, assistant, tool, error }

/// A tool invocation carried by a tool-role message: what tool ran and with
/// what arguments. Mirrors `Tool { name, args }` in the TS `message.ts`.
class ToolInvocation {
  final String name;
  final Map<String, dynamic> args;

  const ToolInvocation({required this.name, required this.args});

  factory ToolInvocation.fromJson(Map<String, dynamic> json) => ToolInvocation(
    name: json['name'] as String,
    args: (json['args'] as Map?)?.cast<String, dynamic>() ?? {},
  );

  Map<String, dynamic> toJson() => {'name': name, 'args': args};
}

/// Base for every chat message. Mirrors `BaseMessage { id, text }`.
sealed class Message {
  final String id;
  final String text;

  MessageRole get role;

  const Message({required this.id, required this.text});

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'role': role.name};
}

class UserMessage extends Message {
  @override
  MessageRole get role => MessageRole.user;

  const UserMessage({required super.id, required super.text});
}

class AssistantMessage extends Message {
  @override
  MessageRole get role => MessageRole.assistant;

  const AssistantMessage({required super.id, required super.text});
}

class ToolMessage extends Message {
  final ToolInvocation tool;
  final String result;

  @override
  MessageRole get role => MessageRole.tool;

  const ToolMessage({
    required super.id,
    required super.text,
    required this.tool,
    required this.result,
  });

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'tool': tool.toJson(),
    'result': result,
  };
}

/// An error surfaced into the conversation. The TS version stores an `Error`;
/// here we keep the error text as a plain string.
class ErrorMessage extends Message {
  final String error;

  @override
  MessageRole get role => MessageRole.error;

  const ErrorMessage({
    required super.id,
    required super.text,
    required this.error,
  });

  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'error': error};
}

/// Rebuilds a `Message` from JSON, dispatching on `role`.
Message messageFromJson(Map<String, dynamic> json) {
  final id = json['id'] as String;
  final text = json['text'] as String;
  final role = json['role'] as String?;
  switch (role) {
    case 'tool':
      return ToolMessage(
        id: id,
        text: text,
        tool: ToolInvocation.fromJson(json['tool'] as Map<String, dynamic>),
        result: json['result'] as String? ?? text,
      );
    case 'error':
      return ErrorMessage(
        id: id,
        text: text,
        error: json['error'] as String? ?? '',
      );
    case 'assistant':
      return AssistantMessage(id: id, text: text);
    default:
      return UserMessage(id: id, text: text);
  }
}
