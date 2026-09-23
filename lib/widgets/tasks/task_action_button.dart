import 'package:flutter/material.dart';

/// Compact Action Icon Button (Prevents overflows).
class TaskActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  const TaskActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: color, size: 18),
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28, maxWidth: 30, maxHeight: 30),
      splashRadius: 16,
    );
  }
}
