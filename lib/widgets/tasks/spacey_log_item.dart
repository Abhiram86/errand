import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../screens/task_file_preview_screen.dart';
import '../../services/database.dart';
import '../../theme/app_colors.dart';
import 'task_action_button.dart';

/// Spacey Unread / Log Item Widget
class SpaceyLogItem extends StatelessWidget {
  final SchedulerTaskLogRow log;
  final SchedulerTaskRow? task;
  final VoidCallback onMarkSeen;

  const SpaceyLogItem({
    super.key,
    required this.log,
    required this.task,
    required this.onMarkSeen,
  });

  @override
  Widget build(BuildContext context) {
    final isUnread = log.notificationSeen == 0;
    final title = task?.title ?? 'Task #${log.schedulerTaskId}';

    return InkWell(
      onTap: () {
        if (isUnread) onMarkSeen();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top: status indicator + timestamp + unread dot
            Row(
              children: [
                _buildStatusIndicator(log.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatTime(log.startedAt ?? log.createdAt),
                    style: TextStyle(color: kMuted.withValues(alpha: 0.7), fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isUnread) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: kBubbleUser,
                    ),
                  ),
                  const SizedBox(width: 6),
                  TaskActionButton(
                    icon: Icons.check_rounded,
                    tooltip: 'Mark as read',
                    color: kMuted,
                    onTap: onMarkSeen,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),

            // Task title
            Text(
              title,
              style: TextStyle(
                color: isUnread ? kText : kText.withValues(alpha: 0.8),
                fontSize: 13,
                fontWeight: isUnread ? FontWeight.w600 : FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),

            // Summary
            if (log.summary != null && log.summary!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                log.summary!,
                style: const TextStyle(color: kMuted, fontSize: 11, height: 1.35),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],

            // Error
            if (log.errorMessage != null && log.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Error: ${log.errorMessage}',
                style: const TextStyle(color: kDanger, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],

            // Output File Link
            if (log.outputFilePath != null && log.outputFilePath!.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  if (isUnread) onMarkSeen();
                  TaskFilePreviewScreen.show(
                    context,
                    filePath: log.outputFilePath!,
                    title: p.basename(log.outputFilePath!),
                  );
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.description_outlined, color: Color(0xFF58A6FF), size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          log.outputFilePath!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0xFF58A6FF),
                            fontSize: 11,
                            decoration: TextDecoration.underline,
                            decorationColor: const Color(0xFF58A6FF).withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF58A6FF).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Preview',
                          style: TextStyle(
                            color: Color(0xFF58A6FF),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(String status) {
    final Color color;
    final String label;
    switch (status) {
      case 'success':
        color = const Color(0xFF4ADE80);
        label = 'SUCCESS';
        break;
      case 'running':
        color = Colors.amberAccent;
        label = 'RUNNING';
        break;
      case 'timeout':
        color = const Color(0xFFFB923C);
        label = 'TIMEOUT';
        break;
      case 'cancelled':
        color = kMuted;
        label = 'CANCELLED';
        break;
      case 'failed':
      default:
        color = const Color(0xFFF87171);
        label = 'FAILED';
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: status == 'running'
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.55),
                      blurRadius: 5,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    if (isToday) return 'Today $timeStr';
    return '${dt.month}/${dt.day} $timeStr';
  }
}

class LogStatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const LogStatChip({
    super.key,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
