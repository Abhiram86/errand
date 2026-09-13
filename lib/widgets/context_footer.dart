import 'package:flutter/material.dart';

import '../agent/context_budget.dart';
import '../theme/app_colors.dart';

String formatTokenCount(int tokens) {
  if (tokens >= 1000000) {
    final m = tokens / 1000000;
    return m % 1 == 0 ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
  }
  if (tokens >= 1000) {
    final k = tokens / 1000;
    return k % 1 == 0 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }
  return '$tokens';
}

/// Displays the current active token usage vs. the dynamic compaction threshold.
class ContextFooter extends StatelessWidget {
  final ContextBudget budget;
  final int activeTokens;
  final int messageCount;
  final bool hasCompacted;

  const ContextFooter({
    super.key,
    required this.budget,
    required this.activeTokens,
    required this.messageCount,
    required this.hasCompacted,
  });

  @override
  Widget build(BuildContext context) {
    final threshold = budget.compactionThreshold;
    final isNearOrOver = activeTokens >= threshold;

    final statusSuffix = isNearOrOver
        ? ' · compacts next'
        : hasCompacted
            ? ' · compacted'
            : '';

    return Material(
      color: kInputBg,
      child: Tooltip(
        message:
            'Context: $activeTokens / $threshold tokens (native max: ${formatTokenCount(budget.contextSize)})',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            'ctx ${formatTokenCount(activeTokens)}/${formatTokenCount(threshold)} · $messageCount msgs$statusSuffix',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isNearOrOver ? const Color(0xFFF59E0B) : kMuted,
              fontSize: 10,
              fontWeight: isNearOrOver ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
