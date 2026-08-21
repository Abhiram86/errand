import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../theme/app_colors.dart';
import '../tools/intent_tool.dart';
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
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_truncateForDisplay(message.tool.name, 32)} '
                    '${_truncateForDisplay(args, kMaxToolHeaderChars)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                ),
                // Reopen button for launch-style intent actions (open_url,
                // open_app, ...): re-fires the same persisted args.
                if (isReopenable(message))
                  _ReopenButton(message: message),
              ],
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

class _ReopenButton extends StatelessWidget {
  final ToolMessage message;

  const _ReopenButton({required this.message});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final outcome = await replayIntentAction(message.tool.args);
        if (outcome.startsWith('ERROR')) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(outcome),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      style: TextButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.open_in_new_rounded, size: 12),
          SizedBox(width: 3),
          Text(
            'Open',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
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

    // Some models emit leading/trailing newlines or fully empty turns;
    // never render an empty bubble for them.
    final text = message.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

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
        child: isUser
            ? SelectableText(
                text,
                style:
                    const TextStyle(color: kText, fontSize: 15, height: 20 / 15),
              )
            // Assistant turns render as markdown (bold, tables, code,
            // LaTeX). Text selection comes from the SelectionArea that
            // wraps the message list.
            : GptMarkdown(
                text,
                style: const TextStyle(color: kText, fontSize: 15),
              ),
      ),
    );
  }
}
