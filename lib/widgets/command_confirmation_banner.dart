import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Interactive modal overlay shown over the composer when the agent attempts
/// to run a destructive or restricted shell command.
///
/// Designed as a modal layer that overlays on top of the composer and browser preview
/// without disturbing browser dock calculations or layout heights.
///
/// Presents three options:
/// - [onDeny]: Rejects tool execution and informs the agent that the user denied.
/// - [onAccept]: Executes this single command.
/// - [onTrust]: Auto-accepts all destructive commands in the active conversation session.
class CommandConfirmationModal extends StatelessWidget {
  final String title;
  final String command;
  final String? reason;
  final VoidCallback onAccept;
  final VoidCallback onDeny;
  final VoidCallback onTrust;

  const CommandConfirmationModal({
    super.key,
    this.title = 'Destructive Command',
    required this.command,
    this.reason,
    required this.onAccept,
    required this.onDeny,
    required this.onTrust,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Semi-transparent backdrop scrim that blocks taps to underlying widgets
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {}, // Intentionally non-dismissible outside explicit action
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
          // Modal card anchored directly at the bottom, layered over composer
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: kBubbleUser.withValues(alpha: 0.55),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.65),
                      blurRadius: 16,
                      spreadRadius: 2,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: Icon + Title + Reason
                    Row(
                      children: [
                        const Icon(
                          Icons.shield_outlined,
                          size: 16,
                          color: Colors.amberAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: kText,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (reason != null && reason!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              reason!,
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Command snippet container
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: kDarkBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kBorder),
                      ),
                      child: SelectableText(
                        command,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Color(0xFFE6EDF3),
                          height: 1.3,
                        ),
                        maxLines: 4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Action Buttons Row: Deny, Trust, Accept
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Deny Button
                        OutlinedButton.icon(
                          onPressed: onDeny,
                          icon: const Icon(Icons.close_rounded, size: 14, color: kDanger),
                          label: const Text(
                            'Deny',
                            style: TextStyle(
                              color: kDanger,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: kDanger.withValues(alpha: 0.45)),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Trust Button
                        OutlinedButton.icon(
                          onPressed: onTrust,
                          icon: const Icon(
                            Icons.verified_user_outlined,
                            size: 14,
                            color: Colors.amberAccent,
                          ),
                          label: const Text(
                            'Trust',
                            style: TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: Colors.amberAccent.withValues(alpha: 0.45),
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Accept Button
                        FilledButton.icon(
                          onPressed: onAccept,
                          icon: const Icon(
                            Icons.check_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'Accept',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: kBubbleUser,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Backwards compatibility alias for [CommandConfirmationModal].
typedef CommandConfirmationBanner = CommandConfirmationModal;
