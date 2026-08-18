import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../types/message.dart';

const kMaxToolHeaderChars = 96;
const kMaxToolOutputChars = 4000;

String _truncateForDisplay(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  return '${value.substring(0, maxChars - 1)}…';
}

String _formatToolArgs(Map<String, dynamic> args) {
  try {
    return jsonEncode(args);
  } catch (_) {
    return args.toString();
  }
}

class ToolMessageBubble extends StatelessWidget {
  final ToolMessage message;

  const ToolMessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final args = _formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = _truncateForDisplay(message.result, kMaxToolOutputChars);

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        child: Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            iconTheme: Theme.of(context).iconTheme
                .copyWith(color: kMuted.withValues(alpha: 0.45), size: 16),
          ),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            collapsedIconColor: kMuted.withValues(alpha: 0.45),
            iconColor: kMuted.withValues(alpha: 0.45),
            dense: true,
            visualDensity: VisualDensity.compact,
            minTileHeight: 24,
            title: Text(
              '${_truncateForDisplay(message.tool.name, 32)} '
              '${_truncateForDisplay(args, kMaxToolHeaderChars)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  outputWasTruncated
                      ? '$output\n\n[output truncated for display]'
                      : output,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? kBubbleUser : kBubbleAssistant,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
        ),
        child: SelectableText(
          message.text,
          style: const TextStyle(color: kText, fontSize: 15, height: 20 / 15),
        ),
      ),
    );
  }
}
