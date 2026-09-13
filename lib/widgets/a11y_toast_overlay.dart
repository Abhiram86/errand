import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Animated floating banner notifying user when screen access / accessibility is paused or blocked.
class A11yToastOverlay extends StatelessWidget {
  final bool show;
  final bool isRestricted;
  final VoidCallback onDismiss;
  final VoidCallback onEnable;

  const A11yToastOverlay({
    super.key,
    required this.show,
    required this.isRestricted,
    required this.onDismiss,
    required this.onEnable,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !show,
        child: SafeArea(
          child: AnimatedSlide(
            offset: show ? Offset.zero : const Offset(0, -1.2),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: show ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: show
                  ? Container(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E212B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: kBorder.withValues(alpha: 0.9),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: kBubbleAssistant,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.settings_accessibility_rounded,
                                  size: 16,
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
                                      isRestricted
                                          ? 'Screen access is blocked'
                                          : 'Screen access is paused',
                                      style: const TextStyle(
                                        color: kText,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isRestricted
                                          ? 'Android blocks Errand ("Restricted setting"). Fix: Settings > Apps > Errand > ⋮ > Allow restricted settings, then enable in Accessibility.'
                                          : 'It pauses when Errand closes. Turn it on to let Errand view or control apps.',
                                      style: const TextStyle(
                                        color: kMuted,
                                        fontSize: 12,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: onDismiss,
                                icon: const Icon(Icons.close_rounded,
                                    size: 16, color: kMuted),
                                tooltip: 'Dismiss',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton(
                              onPressed: onEnable,
                              style: FilledButton.styleFrom(
                                backgroundColor: kBubbleUser,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 6),
                                minimumSize: const Size(0, 30),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Enable',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}
