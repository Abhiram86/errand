import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../types/conversation.dart';
import 'paging.dart';

class ChatSidebar extends StatelessWidget {
  final VoidCallback onClose;
  final ValueChanged<Conversation> onSelectConversation;
  final ValueChanged<Conversation> onDeleteConversation;
  final List<Conversation> pinnedConversations;
  final List<Conversation> conversations;
  final String? activeConversationId;
  final List<ChatOption> Function(Conversation conversation) optionsBuilder;

  /// OPT-07 sidebar pagination.
  final bool hasMoreConversations;
  final bool isLoadingMoreConversations;
  final VoidCallback onLoadMoreConversations;

  const ChatSidebar({
    super.key,
    required this.onClose,
    required this.onSelectConversation,
    required this.onDeleteConversation,
    required this.pinnedConversations,
    required this.conversations,
    required this.activeConversationId,
    required this.optionsBuilder,
    required this.hasMoreConversations,
    required this.isLoadingMoreConversations,
    required this.onLoadMoreConversations,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kInputBg,
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Chats',
                      style: TextStyle(
                        color: kText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Close sidebar',
                    icon: const Icon(Icons.close_rounded),
                    color: kMuted,
                  ),
                ],
              ),
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      hasMoreConversations &&
                      !isLoadingMoreConversations &&
                      shouldLoadMore(notification, PagingEdge.trailing)) {
                    onLoadMoreConversations();
                  }
                  return false;
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  children: [
                    if (pinnedConversations.any((chat) => chat.isPinned)) ...[
                      const _SidebarSectionTitle('Pinned / favourites'),
                      const SizedBox(height: 8),
                      for (final chat in pinnedConversations)
                        _PinnedChatRow(
                          conversation: chat,
                          selected: chat.id == activeConversationId,
                          onTap: () => onSelectConversation(chat),
                          onDelete: () => onDeleteConversation(chat),
                          options: optionsBuilder(chat),
                        ),
                      const SizedBox(height: 28),
                    ],
                    const _SidebarSectionTitle('Recent'),
                    const SizedBox(height: 8),
                    if (conversations.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Text(
                          'Your recent chats will appear here.',
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                    // if (conversations.every((chat) => !chat.isPinned))
                    for (final chat in conversations)
                      if (!chat.isPinned)
                        _RecentChatRow(
                          conversation: chat,
                          selected: chat.id == activeConversationId,
                          onTap: () => onSelectConversation(chat),
                          onDelete: () => onDeleteConversation(chat),
                          options: optionsBuilder(chat),
                        ),
                    if (isLoadingMoreConversations)
                      const LoadMoreIndicator(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSectionTitle extends StatelessWidget {
  final String title;

  const _SidebarSectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: kMuted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _PinnedChatRow extends StatelessWidget {
  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final List<ChatOption> options;

  const _PinnedChatRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    return _SidebarRow(
      leading: const Icon(Icons.push_pin_outlined, color: kMuted, size: 18),
      title: conversation.title,
      selected: selected,
      isPinned: conversation.isPinned,
      onTap: onTap,
      onDelete: onDelete,
      options: options,
    );
  }
}

class _RecentChatRow extends StatelessWidget {
  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final List<ChatOption> options;

  const _RecentChatRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    return _SidebarRow(
      title: conversation.title,
      selected: selected,
      onTap: onTap,
      isPinned: conversation.isPinned,
      onDelete: onDelete,
      options: options,
    );
  }
}

class _SidebarRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final bool isPinned;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final List<ChatOption> options;

  const _SidebarRow({
    this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.isPinned,
    required this.onDelete,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showChatOptions(
            context,
            title: title,
            onDelete: onDelete,
            options: options,
            isPinned: isPinned,
          ),
          borderRadius: BorderRadius.circular(14),
          splashColor: kBubbleAssistant,
          highlightColor: kBubbleAssistant.withValues(alpha: 0.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? kBubbleAssistant : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 10)],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kText, fontSize: 14),
                    ),
                  ),
                  Tooltip(
                    message: 'Chat options',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _showChatOptions(
                          context,
                          title: title,
                          onDelete: onDelete,
                          options: options,
                          isPinned: isPinned,
                        ),
                        onLongPress: () => _showChatOptions(
                          context,
                          title: title,
                          onDelete: onDelete,
                          options: options,
                          isPinned: isPinned,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        child: const SizedBox(
                          width: 28,
                          height: 28,
                          child: Icon(
                            Icons.more_horiz,
                            color: kMuted,
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showChatOptions(
  BuildContext context, {
  required String title,
  required bool isPinned,
  required VoidCallback onDelete,
  required List<ChatOption> options,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kInputBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kText,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),

            const SizedBox(height: 4),

            const Text(
              'Chat options will appear here.',
              style: TextStyle(
                color: kMuted,
                fontSize: 13,
              ),
            ),

            const SizedBox(height: 8),

            ...options.map(
              (option) => ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                contentPadding: EdgeInsets.zero,
                minVerticalPadding: 0,
                leading: Icon(
                  option.icon,
                  color: option.type == ChatOptionType.destructive
                      ? kDanger
                      : kMuted,
                  size: 18,
                ),
                title: Text(
                  option.title == "Pin" ? isPinned ? "Unpin Conversation" : "Pin Conversation" : option.title,
                  style: TextStyle(
                    color: option.type == ChatOptionType.destructive
                        ? kDanger
                        : kMuted,
                    fontSize: 14,
                  ),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  option.onTap();
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum ChatOptionType {
  normal,
  destructive,
}

class ChatOption {
  final String title;
  final IconData icon;
  final ChatOptionType type;
  final VoidCallback onTap;

  const ChatOption({
    required this.title,
    required this.icon,
    this.type = ChatOptionType.normal,
    required this.onTap,
  });
}
