import 'dart:io';

import 'message.dart';

class Conversation {
  final String? localSystemPrompt;
  final List<Message> messages;
  final Directory currentDir;

  const Conversation({
    this.localSystemPrompt,
    required this.messages,
    required this.currentDir,
  });
}
