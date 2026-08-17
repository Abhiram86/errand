/// Conversation model — mirrors `src/types/conversation.ts` from the Expo app.
///
/// One conversation is one chat session: its full message history plus the
/// set of tools available in it. `createdAt`/`updatedAt` are ISO-8601 strings
/// on the wire (mirroring TS `Date`s).
library;

import 'dart:io';

import 'message.dart';

class Conversation {
  final String id;
  final String? localSystemPrompt;
  final List<Message> messages;
  final List<ToolInvocation> tools;
  final Directory currentDir;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Conversation({
    required this.id,
    this.localSystemPrompt,
    required this.messages,
    required this.tools,
    required this.currentDir,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    localSystemPrompt: json['localSystemPrompt'] as String?,
    messages: (json['messages'] as List)
        .map((m) => messageFromJson(m as Map<String, dynamic>))
        .toList(),
    tools: (json['tools'] as List)
        .map((t) => ToolInvocation.fromJson(t as Map<String, dynamic>))
        .toList(),
    currentDir: Directory(
      json['currentDir'] as String? ?? '/storage/emulated/0',
    ),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (localSystemPrompt != null) 'localSystemPrompt': localSystemPrompt,
    'messages': messages.map((m) => m.toJson()).toList(),
    'tools': tools.map((t) => t.toJson()).toList(),
    'currentDir': currentDir.path,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
