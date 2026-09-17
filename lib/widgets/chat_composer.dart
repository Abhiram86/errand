import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class ChatComposer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
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
    this.focusNode,
    required this.busy,
    required this.onMoreActions,
    required this.onSend,
    required this.onStop,
    required this.onMic,
    required this.isListening,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    if (widget.busy) {
      _glowController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy != oldWidget.busy) {
      if (widget.busy) {
        _glowController.repeat();
      } else {
        _glowController.stop();
        _glowController.reset();
      }
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: kDarkBg,
        border: Border(top: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: widget.busy
          ? AnimatedBuilder(
              animation: _glowController,
              builder: (context, child) {
                return Container(
                  padding: const EdgeInsets.all(1.4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: SweepGradient(
                      transform: GradientRotation(
                        _glowController.value * 2 * math.pi,
                      ),
                      colors: const [
                        kBubbleUser,
                        kMuted,
                        kDarkBg,
                        kMuted,
                        kBubbleUser,
                      ],
                      stops: const [0.0, 0.35, 0.65, 0.85, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: kBubbleUser.withValues(alpha: 0.35),
                        blurRadius: 10,
                        spreadRadius: 0.5,
                      ),
                      BoxShadow(
                        color: kBubbleUser.withValues(alpha: 0.12),
                        blurRadius: 18,
                        spreadRadius: 1.5,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: _buildInner(),
            )
          : Container(
              padding: const EdgeInsets.all(1.2),
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(24),
              ),
              child: _buildInner(),
            ),
    );
  }

  Widget _buildInner() {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 6),
      decoration: BoxDecoration(
        color: kInputBg,
        borderRadius: BorderRadius.circular(22.8),
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
                onPressed: widget.busy ? null : widget.onMoreActions,
                tooltip: 'More actions',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                icon: Icon(
                  Icons.add,
                  color: widget.busy ? kMuted : kText,
                  size: 22,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: !widget.busy,
              keyboardType: TextInputType.multiline,
              minLines: 1,
              maxLines: 4,
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
          if (widget.busy)
            _SendButton(
              stop: true,
              canSend: true,
              onPressed: widget.onStop,
            )
          else
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, child) {
                final hasText = value.text.trim().isNotEmpty;
                return ValueListenableBuilder<bool>(
                  valueListenable: widget.isListening,
                  builder: (context, listening, child) => _SendButton(
                    canSend: true,
                    onPressed: hasText ? widget.onSend : widget.onMic,
                    mic: !hasText,
                    listening: listening,
                  ),
                );
              },
            ),
        ],
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
