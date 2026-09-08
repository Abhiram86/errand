import 'package:flutter/foundation.dart';
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

  /// Toggles voice input; offered when the composer is empty.
  final VoidCallback onMic;

  /// True while a speech-recognition session is active (mic turns red).
  final ValueListenable<bool> isListening;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.busy,
    required this.onMoreActions,
    required this.onSend,
    required this.onStop,
    required this.onMic,
    required this.isListening,
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
                keyboardType: TextInputType.multiline,
                minLines: 1,
                maxLines: 4,
                // Enter inserts a newline — messages send only via the
                // send button, never from the keyboard action.
                textInputAction: TextInputAction.newline,
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
            // Right button state machine:
            // busy            → square stop (cancel the turn)
            // empty composer  → mic (voice input; red while listening)
            // has text        → send arrow
            if (busy)
              _SendButton(stop: true, canSend: true, onPressed: onStop)
            else
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, child) {
                  final hasText = value.text.trim().isNotEmpty;
                  return ValueListenableBuilder<bool>(
                    valueListenable: isListening,
                    builder: (context, listening, child) => _SendButton(
                      canSend: true,
                      onPressed: hasText ? onSend : onMic,
                      mic: !hasText,
                      listening: listening,
                    ),
                  );
                },
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

  /// Renders as a mic button (voice input) instead of the send arrow.
  final bool mic;

  /// While listening, the mic turns red — tap again to stop.
  final bool listening;
  final VoidCallback? onPressed;

  const _SendButton({
    required this.canSend,
    required this.onPressed,
    this.stop = false,
    this.mic = false,
    this.listening = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color background;
    if (stop || (mic && listening)) {
      // Stop and an active mic both read as "tap to end": accent for stop,
      // danger red for the live mic.
      background = stop ? kBubbleUser : kDanger;
    } else {
      background = kBubbleUser;
    }
    return SizedBox(
      width: 38,
      height: 38,
      child: IconButton(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: background,
          shape: stop
              ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              : const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        icon: stop
            ? const Icon(Icons.stop_rounded, color: Colors.white, size: 24)
            : mic
                ? Icon(
                    Icons.mic_rounded,
                    color: Colors.white,
                    size: listening ? 22 : 20,
                  )
                : const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
      ),
    );
  }
}
