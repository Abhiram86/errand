import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../screens/task_file_preview_screen.dart';
import '../../services/database.dart';
import '../../services/task_scheduler_service.dart';
import '../../theme/app_colors.dart';
import 'task_action_button.dart';

/// Spacey Unread / Log Item Widget
class SpaceyLogItem extends StatefulWidget {
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
  State<SpaceyLogItem> createState() => _SpaceyLogItemState();
}

class _SpaceyLogItemState extends State<SpaceyLogItem> {
  bool _isExpanded = false;

  IconData _iconForPath(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.csv':
      case '.tsv':
      case '.json':
        return Icons.table_chart_outlined;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.webp':
      case '.gif':
      case '.svg':
        return Icons.image_outlined;
      case '.pdf':
        return Icons.picture_as_pdf_outlined;
      case '.html':
        return Icons.html_outlined;
      case '.md':
      case '.txt':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUnread = widget.log.notificationSeen == 0;
    final title = widget.task?.title ?? 'Task #${widget.log.schedulerTaskId}';
    final linkedFiles = TaskSchedulerService.parseLinkedFiles(widget.log.linkedFiles);

    return InkWell(
      onTap: () {
        if (isUnread) widget.onMarkSeen();
        if (linkedFiles.isNotEmpty) {
          setState(() {
            _isExpanded = !_isExpanded;
          });
        }
      },
      // Deliberately undiscoverable: long-press a RUNNING row to copy its
      // live trace (status, heartbeat age, current step). No icon, no menu —
      // this is a debug affordance, not user-facing UI.
      onLongPress:
          widget.log.status == 'running' ? _copyLiveTrace : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top: status indicator + timestamp + unread dot + expand indicator
            Row(
              children: [
                _buildStatusIndicator(widget.log.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatTime(widget.log.startedAt ?? widget.log.createdAt),
                    style: TextStyle(color: kMuted.withValues(alpha: 0.7), fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (linkedFiles.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      _isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      color: kMuted.withValues(alpha: 0.7),
                      size: 16,
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
                    onTap: widget.onMarkSeen,
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
              maxLines: _isExpanded ? null : 2,
              overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),

            // Summary
            if (widget.log.summary != null && widget.log.summary!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                widget.log.summary!,
                style: const TextStyle(color: kMuted, fontSize: 11, height: 1.35),
                maxLines: _isExpanded ? null : 3,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
            ],

            // Error
            if (widget.log.errorMessage != null && widget.log.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Error: ${widget.log.errorMessage}',
                style: const TextStyle(color: kDanger, fontSize: 11),
                maxLines: _isExpanded ? null : 2,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
            ],

            // Primary Output Report File Link
            if (widget.log.outputFilePath != null && widget.log.outputFilePath!.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  if (isUnread) widget.onMarkSeen();
                  final resolvedPath = TaskSchedulerService.resolveReportPath(widget.log.outputFilePath);
                  TaskFilePreviewScreen.show(
                    context,
                    filePath: resolvedPath,
                    title: p.basename(resolvedPath),
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
                          widget.log.outputFilePath!,
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

            // Collapsed linked files hint
            if (!_isExpanded && linkedFiles.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.attach_file_rounded, color: kMuted, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    '${linkedFiles.length} linked file${linkedFiles.length == 1 ? '' : 's'} (tap to view)',
                    style: TextStyle(
                      color: kMuted.withValues(alpha: 0.85),
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ],

            // Expanded Linked Files Section
            if (_isExpanded && linkedFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: kBorder.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.attach_file_rounded, color: Color(0xFF58A6FF), size: 13),
                        const SizedBox(width: 4),
                        Text(
                          'Linked Files (${linkedFiles.length})',
                          style: const TextStyle(
                            color: kText,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...linkedFiles.map((fileRelPath) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: InkWell(
                          onTap: () {
                            if (isUnread) widget.onMarkSeen();
                            final resolvedPath = TaskSchedulerService.resolveReportPath(fileRelPath);
                            TaskFilePreviewScreen.show(
                              context,
                              filePath: resolvedPath,
                              title: p.basename(resolvedPath),
                            );
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                            child: Row(
                              children: [
                                Icon(_iconForPath(fileRelPath), color: const Color(0xFF58A6FF), size: 13),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    fileRelPath,
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
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF58A6FF).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Preview',
                                    style: TextStyle(
                                      color: Color(0xFF58A6FF),
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
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
    String label;
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

    // Heartbeat age on the running chip: fresh means the runner is alive and
    // writing; stale means the isolate died without an outcome (see
    // _copyLiveTrace). Small and inline — the only visible part of this.
    if (status == 'running') {
      final beat = widget.log.lastHeartbeatAt;
      if (beat != null) {
        final age =
            DateTime.now().millisecondsSinceEpoch - beat;
        label = age > 5 * 60 * 1000
            ? 'RUNNING · STALE ${_formatAge(age)}'
            : 'RUNNING · ${_formatAge(age)}';
      }
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

  /// Copies a live diagnostic snapshot of a RUNNING row: status, start age,
  /// heartbeat age (alive vs stale), and the runner's current step. Reached
  /// only via long-press (see build); values come from the log row, so this
  /// works across isolates — a dead background runner simply shows a stale
  /// heartbeat, which is itself the diagnosis. Nothing is stored for this:
  /// the step is overwritten in place and dies with the row's lifecycle.
  void _copyLiveTrace() {
    final log = widget.log;
    if (log.status != 'running') return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = log.startedAt ?? log.createdAt;
    final beat = log.lastHeartbeatAt;
    final String beatLine;
    if (beat == null) {
      beatLine = 'Last heartbeat: none recorded';
    } else {
      final age = now - beat;
      beatLine = age > 5 * 60 * 1000
          ? 'Last heartbeat: ${_formatAge(age)} ago — STALE (runner may be dead)'
          : 'Last heartbeat: ${_formatAge(age)} ago — alive';
    }
    final step = (log.currentStep?.isNotEmpty ?? false) ? log.currentStep! : '—';
    final text = [
      'Task #${log.schedulerTaskId} "${widget.task?.title ?? ''}" — RUNNING (log #${log.id})',
      'Started: ${_formatTime(started)} (${_formatAge(now - started)} ago)',
      beatLine,
      'Current step: $step',
    ].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Live trace copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  static String _formatAge(int millis) {
    final s = millis ~/ 1000;
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    if (h < 48) return '${h}h';
    return '${h ~/ 24}d';
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
