import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../theme/app_colors.dart';
import '../../types/message.dart';
import 'clamped_table_view.dart';

class CompactedDividerBubble extends StatefulWidget {
  final CompactedNoticeMessage message;

  const CompactedDividerBubble({super.key, required this.message});

  @override
  State<CompactedDividerBubble> createState() => _CompactedDividerBubbleState();
}

class _CompactedDividerBubbleState extends State<CompactedDividerBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final summary = widget.message.summary.trim();
    final hasSummary = summary.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Divider(color: kBorder, height: 1, thickness: 0.5),
              ),
              InkWell(
                onTap: hasSummary
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'compacted',
                        style: TextStyle(
                          color: kMuted.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4,
                        ),
                      ),
                      if (hasSummary) ...[
                        const SizedBox(width: 3),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 13,
                          color: kMuted.withValues(alpha: 0.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Expanded(
                child: Divider(color: kBorder, height: 1, thickness: 0.5),
              ),
            ],
          ),
          if (_expanded && hasSummary)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.9,
              ),
              decoration: BoxDecoration(
                color: kInputBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: GptMarkdown(
                summary,
                style: const TextStyle(color: kText, fontSize: 13),
                tableBuilder: buildClampedTable,
              ),
            ),
        ],
      ),
    );
  }
}
