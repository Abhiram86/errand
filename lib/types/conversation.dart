import 'dart:io';

import 'message.dart';

class Conversation {
  String? id;

  final String? localSystemPrompt;
  final List<Message> messages;
  final Directory currentDir;
  final List<String> attachedFileUris;

  String title;
  String? provider;
  String? model;
  bool isPinned;

  final DateTime createdAt;
  DateTime updatedAt;

  Conversation({
    this.id,
    this.localSystemPrompt,
    required this.messages,
    required this.currentDir,
    List<String>? attachedFileUris,
    this.title = '',
    this.provider,
    this.model,
    this.isPinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : attachedFileUris = attachedFileUris ?? [],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
}
