import '../../types/message.dart';

/// Represents a grouped or single display item for the chat message list.
sealed class ChatDisplayItem {
  final String id;
  const ChatDisplayItem(this.id);
}

/// A standard non-tool chat message (User, Assistant, CompactedNotice, etc.).
class SingleMessageDisplayItem extends ChatDisplayItem {
  final Message message;
  final int originalIndex;
  SingleMessageDisplayItem(this.message, this.originalIndex)
      : super(message.id);
}

/// A group of one or more sequential [ToolMessage]s.
class ToolGroupDisplayItem extends ChatDisplayItem {
  final List<ToolMessage> tools;
  ToolGroupDisplayItem(this.tools) : super('group_${tools.first.id}');
}

/// Groups consecutive [ToolMessage]s in [messages] together for display.
List<ChatDisplayItem> groupMessagesForDisplay(List<Message> messages) {
  final items = <ChatDisplayItem>[];
  List<ToolMessage>? currentTools;

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is ToolMessage) {
      currentTools ??= [];
      currentTools.add(message);
    } else if (message is AssistantMessage && message.text.trim().isEmpty) {
      // Stray whitespace/empty assistant messages (e.g. from model newline deltas
      // preceding a tool call) must never break consecutive tool grouping.
      continue;
    } else {
      if (currentTools != null) {
        items.add(ToolGroupDisplayItem(currentTools));
        currentTools = null;
      }
      items.add(SingleMessageDisplayItem(message, i));
    }
  }
  if (currentTools != null) {
    items.add(ToolGroupDisplayItem(currentTools));
  }
  return items;
}
