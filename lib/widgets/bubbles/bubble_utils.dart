import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../types/message.dart';

const kMaxToolHeaderChars = 96;
const kMaxToolOutputChars = 4000;

String truncateForDisplay(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  return '${value.substring(0, maxChars - 1)}…';
}

String formatToolArgs(Map<String, dynamic> args) {
  try {
    return jsonEncode(args);
  } catch (_) {
    return args.toString();
  }
}

String formatToolCallDebugCopy(ToolMessage message) {
  String formattedArgs;
  try {
    const encoder = JsonEncoder.withIndent('  ');
    formattedArgs = encoder.convert(message.tool.args);
  } catch (_) {
    formattedArgs = message.tool.args.toString();
  }
  return 'Tool: ${message.tool.name}\nArguments: $formattedArgs\nOutput:\n${message.result}';
}

/// One-tap copy for assistant text and tool output. Free-form selection
/// still comes from the SelectionArea wrapping the message list.
class CopyButton extends StatelessWidget {
  final String text;
  final String tooltip;

  const CopyButton({super.key, required this.text, this.tooltip = 'Copy'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () async {
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
      tooltip: tooltip,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      padding: EdgeInsets.zero,
      iconSize: 14,
      color: kMuted,
      icon: const Icon(Icons.copy_rounded),
    );
  }
}

/// Smooth, subtle entry transition for new messages and tool calls.
/// Glides up by ~4% and fades in over 260ms without causing layout reflow.
class SubtleFadeIn extends StatefulWidget {
  final Widget child;
  final bool animate;
  final Duration duration;

  const SubtleFadeIn({
    super.key,
    required this.child,
    this.animate = true,
    this.duration = const Duration(milliseconds: 260),
  });

  @override
  State<SubtleFadeIn> createState() => _SubtleFadeInState();
}

class _SubtleFadeInState extends State<SubtleFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeAnimation = curve;
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(curve);

    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.child;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}
