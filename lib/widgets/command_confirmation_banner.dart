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
    final explanation = CommandRiskExplanation.explain(command, reason: reason);
    final displayTitle = title != 'Destructive Command' ? title : explanation.title;

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
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
          // Modal card anchored directly at the bottom, layered over composer
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                ),
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: explanation.accentColor.withValues(alpha: 0.55),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.75),
                        blurRadius: 18,
                        spreadRadius: 2,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header: Icon + Friendly Title + Reason badge
                          Row(
                            children: [
                              Icon(
                                explanation.icon,
                                size: 18,
                                color: explanation.accentColor,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  displayTitle,
                                  style: const TextStyle(
                                    color: kText,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (reason != null && reason!.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 130),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: explanation.accentColor.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: explanation.accentColor.withValues(alpha: 0.3),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        reason!,
                                        style: TextStyle(
                                          color: explanation.accentColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),

                          // Plain-English Impact Card (Normie-friendly)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0D1117),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: explanation.isIrreversible
                                    ? kDanger.withValues(alpha: 0.3)
                                    : kBorder,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (explanation.target != null) ...[
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.folder_open_rounded,
                                        size: 13,
                                        color: kMuted,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          explanation.target!,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFE6EDF3),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                Text(
                                  explanation.impact,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: explanation.isIrreversible
                                        ? const Color(0xFFFF7B72)
                                        : kMuted,
                                    fontWeight: explanation.isIrreversible
                                        ? FontWeight.w500
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),

                          // Technical Command Box
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: kDarkBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: kBorder),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: const [
                                    Icon(Icons.terminal_rounded, size: 11, color: kMuted),
                                    SizedBox(width: 4),
                                    Text(
                                      'Shell command',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                        color: kMuted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxHeight: 76),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      command,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11.5,
                                        color: Color(0xFFE6EDF3),
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Action Buttons: Deny, Trust, Accept
                          Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
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
                                    backgroundColor: explanation.isIrreversible
                                        ? const Color(0xFFDA3633)
                                        : kBubbleUser,
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
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper that analyzes a shell command and generates plain-language,
/// non-technical explanations of what will be affected and the risk involved.
class CommandRiskExplanation {
  final String title;
  final String? target;
  final String impact;
  final IconData icon;
  final Color accentColor;
  final bool isIrreversible;

  const CommandRiskExplanation({
    required this.title,
    this.target,
    required this.impact,
    required this.icon,
    required this.accentColor,
    this.isIrreversible = false,
  });

  static CommandRiskExplanation explain(String command, {String? reason}) {
    final clean = command.trim();
    final parts = clean.split(RegExp(r'\s+'));
    final cmd = parts.first.split('/').last.replaceAll(RegExp(r'["'']'), '');

    if (cmd == 'rm' || cmd == 'rmdir') {
      final isRecursive = clean.contains('-r') || clean.contains('-R') || clean.contains('--recursive');
      final isWildcard = clean.contains('*') || clean.contains('?');
      final target = parts.where((p) => !p.startsWith('-')).skip(1).join(' ').replaceAll(RegExp(r'["'']'), '');

      if (isRecursive) {
        return CommandRiskExplanation(
          title: target.isNotEmpty ? 'Delete Folder "${_shorten(target)}"' : 'Delete Folder & Contents',
          target: target.isNotEmpty ? target : null,
          impact: 'Permanently deletes this entire directory and all files inside it. This cannot be undone.',
          icon: Icons.delete_forever_rounded,
          accentColor: kDanger,
          isIrreversible: true,
        );
      }
      if (isWildcard) {
        return CommandRiskExplanation(
          title: 'Bulk Delete Matching Files',
          target: target.isNotEmpty ? target : null,
          impact: 'Permanently deletes all matching files in this directory.',
          icon: Icons.delete_sweep_rounded,
          accentColor: kDanger,
          isIrreversible: true,
        );
      }
      return CommandRiskExplanation(
        title: target.isNotEmpty ? 'Delete File "${_shorten(target)}"' : 'Delete File',
        target: target.isNotEmpty ? target : null,
        impact: 'Permanently removes this file from your device.',
        icon: Icons.delete_outline_rounded,
        accentColor: kDanger,
        isIrreversible: true,
      );
    }

    if (cmd == 'mv') {
      final targets = parts.where((p) => !p.startsWith('-')).skip(1).toList();
      final targetStr = targets.length >= 2 ? '${targets[0]} → ${targets[1]}' : targets.join(' ');
      return CommandRiskExplanation(
        title: 'Move or Rename File',
        target: targetStr.isNotEmpty ? targetStr : null,
        impact: 'Moves or renames files on your device. May overwrite existing files at the destination.',
        icon: Icons.drive_file_move_rounded,
        accentColor: Colors.amberAccent,
      );
    }

    if (cmd == 'cp') {
      final targets = parts.where((p) => !p.startsWith('-')).skip(1).toList();
      final targetStr = targets.length >= 2 ? '${targets[0]} → ${targets[1]}' : targets.join(' ');
      return CommandRiskExplanation(
        title: 'Copy File Outside Scratch',
        target: targetStr.isNotEmpty ? targetStr : null,
        impact: 'Copies files to a permanent storage directory and may replace files if they exist.',
        icon: Icons.copy_rounded,
        accentColor: Colors.amberAccent,
      );
    }

    if (cmd == 'sed' && clean.contains('-i')) {
      final targets = parts.where((p) => !p.startsWith('-') && !p.startsWith('s/')).skip(1).join(' ');
      return CommandRiskExplanation(
        title: 'Edit File In-Place',
        target: targets.isNotEmpty ? targets : null,
        impact: 'Directly modifies text inside this file without keeping an original backup.',
        icon: Icons.edit_note_rounded,
        accentColor: Colors.amberAccent,
      );
    }

    if (cmd == 'mkdir' || cmd == 'touch') {
      final target = parts.where((p) => !p.startsWith('-')).skip(1).join(' ');
      return CommandRiskExplanation(
        title: cmd == 'mkdir' ? 'Create New Directory' : 'Create New File',
        target: target.isNotEmpty ? target : null,
        impact: 'Creates permanent files or folders on your device outside the workspace scratchpad.',
        icon: cmd == 'mkdir' ? Icons.create_new_folder_rounded : Icons.note_add_rounded,
        accentColor: Colors.blueAccent,
      );
    }

    if (cmd == 'pm') {
      return CommandRiskExplanation(
        title: 'Modify Installed App',
        target: parts.skip(1).join(' '),
        impact: 'Changes settings or state of an application installed on your Android device.',
        icon: Icons.android_rounded,
        accentColor: kDanger,
        isIrreversible: true,
      );
    }

    if (cmd == 'settings') {
      return CommandRiskExplanation(
        title: 'Change Device Setting',
        target: parts.skip(1).join(' '),
        impact: 'Modifies an Android system setting preference.',
        icon: Icons.settings_suggest_rounded,
        accentColor: Colors.blueAccent,
      );
    }

    return CommandRiskExplanation(
      title: reason ?? 'Restricted Shell Action',
      target: null,
      impact: 'This command performs system or file modifications that require your explicit approval.',
      icon: Icons.warning_amber_rounded,
      accentColor: Colors.amberAccent,
    );
  }

  static String _shorten(String path) {
    final clean = path.replaceAll(RegExp(r'/+$'), '');
    final name = clean.split('/').last;
    return name.isNotEmpty ? name : clean;
  }
}

/// Backwards compatibility alias for [CommandConfirmationModal].
typedef CommandConfirmationBanner = CommandConfirmationModal;
