import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../types/conversation.dart';

class ChatSidebar extends StatelessWidget {
  final VoidCallback onClose;
  final ValueChanged<Conversation> onSelectConversation;
  final List<Conversation> conversations;
  final String? activeConversationId;

  const ChatSidebar({
    super.key,
    required this.onClose,
    required this.onSelectConversation,
    required this.conversations,
    required this.activeConversationId,
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                children: [
                  if (conversations.any((chat) => chat.isPinned)) ...[
                    const _SidebarSectionTitle('Pinned / favourites'),
                    const SizedBox(height: 8),
                    for (final chat in conversations)
                      if (chat.isPinned)
                        _PinnedChatRow(
                          conversation: chat,
                          selected: chat.id == activeConversationId,
                          onTap: () => onSelectConversation(chat),
                        ),
                    const SizedBox(height: 28),
                  ],
                  const _SidebarSectionTitle('Recent'),
                  const SizedBox(height: 8),
                  if (conversations.every((chat) => !chat.isPinned))
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
                  for (final chat in conversations)
                    if (!chat.isPinned)
                      _RecentChatRow(
                        conversation: chat,
                        selected: chat.id == activeConversationId,
                        onTap: () => onSelectConversation(chat),
                      ),
                ],
              ),
            ),
            const _ProfileFooter(),
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

  const _PinnedChatRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _SidebarRow(
      leading: const Icon(Icons.push_pin_outlined, color: kMuted, size: 18),
      title: conversation.title,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _RecentChatRow extends StatelessWidget {
  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  const _RecentChatRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _SidebarRow(
      title: conversation.title,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _SidebarRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarRow({
    this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
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
                        onTap: () => _showChatOptions(context, title),
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

class _ProfileFooter extends StatelessWidget {
  const _ProfileFooter();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kBorder, width: 0.6)),
      ),
      child: Transform.translate(
        offset: const Offset(0, 5),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: kBubbleUser,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text(
                'JD',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 9),
            const Text(
              'John Doe',
              style: TextStyle(
                color: kText,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showChatOptions(BuildContext context, String chatTitle) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kInputBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chatTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Chat options will appear here.',
              style: TextStyle(color: kMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  );
}
