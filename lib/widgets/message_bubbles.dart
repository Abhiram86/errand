import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// One-tap copy for assistant text and tool output. Free-form selection
/// still comes from the SelectionArea wrapping the message list.
class _CopyButton extends StatelessWidget {
  final String text;
  final String tooltip;

  const _CopyButton({required this.text, this.tooltip = 'Copy'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      padding: EdgeInsets.zero,
      iconSize: 14,
      color: kMuted,
      icon: const Icon(Icons.copy_rounded),
    );
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
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
                    // Copies the full (untruncated) result.
                    _CopyButton(text: message.result, tooltip: 'Copy output'),
                  ],
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

  /// User bubbles only: load the text into the composer for edit-resend.
  final VoidCallback? onEdit;

  /// Assistant bubbles only: drop the turns after the last user message
  /// and re-run. Only wired for the last message of a completed turn.
  final VoidCallback? onRegenerate;

  const MessageBubble({
    super.key,
    required this.message,
    this.onEdit,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;

    // Some models emit leading/trailing newlines or fully empty turns;
    // never render an empty bubble for them.
    final text = message.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * (isUser ? 0.78 : 0.82),
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
              style: const TextStyle(
                color: kText,
                fontSize: 15,
                height: 20 / 15,
              ),
            )
          // Assistant turns render as markdown (bold, tables, code,
          // LaTeX). Text selection comes from the SelectionArea that
          // wraps the message list.
          : GptMarkdown(
              text,
              style: const TextStyle(color: kText, fontSize: 15),
            ),
    );

    // User bubbles carry an explicit pen affordance on their left — more
    // discoverable than tap-to-edit and immune to the SelectionArea
    // swallowing taps on desktop/pointer devices.
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (onEdit != null)
              Transform.translate(
                offset: const Offset(0, -6),
                child: IconButton(
                  onPressed: onEdit,
                  tooltip: 'Edit',
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 24),
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  color: kMuted,
                  icon: const Icon(Icons.edit_rounded),
                ),
              ),
            Flexible(child: bubble),
          ],
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          Transform.translate(
            offset: const Offset(-8, -8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CopyButton(text: text),
                if (onRegenerate != null)
                  Transform.translate(
                    offset: const Offset(-6, 0),
                    child: IconButton(
                      onPressed: onRegenerate,
                      tooltip: 'Regenerate',
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      color: kMuted,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
