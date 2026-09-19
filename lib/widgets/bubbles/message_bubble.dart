import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as path;

import '../../theme/app_colors.dart';
import '../../types/message.dart';
import '../options_modal_sheet.dart';
import 'bubble_utils.dart';
import 'clamped_table_view.dart';

void _showUserMessageOptions(
  BuildContext context, {
  required String text,
  VoidCallback? onEdit,
  VoidCallback? onRetry,
}) {
  showOptionsModalSheet<void>(
    context,
    options: [
      if (onEdit != null)
        SheetOption(
          title: 'Edit',
          icon: Icons.edit_rounded,
          onTap: onEdit,
        ),
      SheetOption(
        title: 'Copy message',
        icon: Icons.copy_rounded,
        onTap: () async {
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
      ),
      if (onRetry != null)
        SheetOption(
          title: 'Retry',
          icon: Icons.refresh_rounded,
          onTap: onRetry,
        ),
    ],
  );
}

class MessageBubble extends StatelessWidget {
  final Message message;

  /// User bubbles only: load the text into the composer for edit-resend.
  final VoidCallback? onEdit;

  /// User bubbles only: drop the turns after this user message and re-run.
  final VoidCallback? onRetry;

  /// Assistant bubbles only: drop the turns after the last user message
  /// and re-run. Only wired for the last message of a completed turn.
  final VoidCallback? onRegenerate;

  const MessageBubble({
    super.key,
    required this.message,
    this.onEdit,
    this.onRetry,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;

    // Some models emit leading/trailing newlines or fully empty turns;
    // never render an empty bubble for them.
    final text = message.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final isPlaceholder =
        !isUser &&
        (text.startsWith('…working') ||
            text.startsWith('…thinking') ||
            text.startsWith('…compacting'));

    return LayoutBuilder(
      builder: (context, constraints) {
        // availableWidth is the width inside the message list excluding outer paddings/margins.
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (MediaQuery.of(context).size.width - 32);

        if (isUser) {
          final bubble = Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: availableWidth * 0.78,
            ),
            decoration: const BoxDecoration(
              color: kBubbleUser,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topRight,
              clipBehavior: Clip.none,
              child: Text(
                text,
                style: const TextStyle(
                  color: kText,
                  fontSize: 15,
                  height: 20 / 15,
                ),
              ),
            ),
          );

          final attached = (message is UserMessage)
              ? (message as UserMessage).attachedUris
              : const <String>[];
          final interactiveBubble = SelectionContainer.disabled(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showUserMessageOptions(
                context,
                text: text,
                onEdit: onEdit,
                onRetry: onRetry,
              ),
              onLongPress: () => _showUserMessageOptions(
                context,
                text: text,
                onEdit: onEdit,
                onRetry: onRetry,
              ),
              child: bubble,
            ),
          );
          final card = Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: BoxConstraints(maxWidth: availableWidth * 0.78),
            decoration: BoxDecoration(
              color: kInputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < attached.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == attached.length - 1 ? 0 : 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.attach_file_rounded,
                          size: 14,
                          color: kMuted,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${i + 1}. ${path.basename(attached[i])}',
                            style: const TextStyle(
                              color: kText,
                              fontSize: 12,
                              height: 1.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Align(
              alignment: Alignment.centerRight,
              child: attached.isEmpty
                  ? interactiveBubble
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [interactiveBubble, card],
                    ),
            ),
          );
        }

        // Assistant turns (ChatGPT style): full width, transparent container, direct text layout
        final assistantTextWidget = SizedBox(
          width: availableWidth,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            clipBehavior: Clip.none,
            child: _StreamingAssistantText(text: text),
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                assistantTextWidget,
                if (!isPlaceholder)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        CopyButton(text: text),
                        if (onRegenerate != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: onRegenerate,
                            tooltip: 'Regenerate',
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            constraints: const BoxConstraints.tightFor(
                              width: 24,
                              height: 24,
                            ),
                            padding: EdgeInsets.zero,
                            iconSize: 14,
                            color: kMuted,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                        if (message is AssistantMessage &&
                            (message as AssistantMessage).model != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: kInputBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: kBorder.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Text(
                              (message as AssistantMessage).model!,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StreamingAssistantText extends StatelessWidget {
  final String text;

  const _StreamingAssistantText({required this.text});

  @override
  Widget build(BuildContext context) {
    final isPlaceholder =
        text.startsWith('…working') ||
        text.startsWith('…thinking') ||
        text.startsWith('…compacting');

    if (isPlaceholder) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            color: kMuted.withValues(alpha: 0.85),
            fontSize: 14,
            fontStyle: FontStyle.italic,
            height: 1.3,
          ),
        ),
      );
    }

    return GptMarkdown(
      text,
      style: const TextStyle(
        color: kText,
        fontSize: 15,
        height: 1.45,
      ),
      tableBuilder: buildClampedTable,
    );
  }
}
