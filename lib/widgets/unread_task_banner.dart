import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Top-of-screen reminder for execution results that have not been opened.
class UnreadTaskBanner extends StatelessWidget {
  final int count;
  final VoidCallback onView;
  final VoidCallback onDismiss;

  const UnreadTaskBanner({
    super.key,
    required this.count,
    required this.onView,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final noun = count == 1 ? 'task result' : 'task results';

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: kInputBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: kBubbleAssistant,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.mark_email_unread_rounded,
                    size: 18,
                    color: kText,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$count unread $noun',
                        style: const TextStyle(
                          color: kText,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Review the latest task activity.',
                        style: TextStyle(
                          color: kMuted,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onView,
                  style: FilledButton.styleFrom(
                    backgroundColor: kBubbleUser,
                    foregroundColor: kText,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  child: const Text(
                    'View',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: kMuted,
                  ),
                  tooltip: 'Dismiss',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
