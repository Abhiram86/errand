import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onMoreActions;
  final VoidCallback onSend;

  /// Requests cancellation of the in-flight turn; replaces the send button
  /// (square stop icon) while [busy].
  final VoidCallback onStop;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.busy,
    required this.onMoreActions,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: kDarkBg,
        border: Border(top: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Container(
        padding: const EdgeInsets.only(left: 8, right: 6),
        decoration: BoxDecoration(
          color: kInputBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Transform.translate(
                offset: const Offset(0, -1),
                child: IconButton(
                  onPressed: busy ? null : onMoreActions,
                  tooltip: 'More actions',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: Icon(Icons.add, color: busy ? kMuted : kText, size: 22),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: const TextStyle(color: kText, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Message Errand…',
                  hintStyle: TextStyle(color: kMuted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // While a turn is in flight the send button becomes a square
            // stop button; otherwise it enables with the composer text.
            if (busy)
              _SendButton(stop: true, canSend: true, onPressed: onStop)
            else
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, child) => _SendButton(
                  canSend: value.text.trim().isNotEmpty,
                  onPressed: onSend,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool canSend;

  /// Renders as a square stop button wired to [ChatComposer.onStop].
  final bool stop;
  final VoidCallback? onPressed;

  const _SendButton({
    required this.canSend,
    required this.onPressed,
    this.stop = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: IconButton(
        onPressed: (stop || canSend) ? onPressed : null,
        style: IconButton.styleFrom(
          backgroundColor: (stop || canSend) ? kBubbleUser : kSendDisabled,
          shape: stop
              ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              : const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        icon: stop
            ? const Icon(Icons.stop_rounded, color: Colors.white, size: 24)
            : const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
      ),
    );
  }
}
