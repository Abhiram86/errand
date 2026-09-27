import 'dart:async';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/database.dart';
import '../../services/task_progress_service.dart';
import '../../services/task_scheduler_service.dart';
import '../../theme/app_colors.dart';
import 'task_action_button.dart';
import 'task_timing_info.dart';

class SpaceyTaskRow extends StatefulWidget {
  final SchedulerTaskRow task;
  final List<SchedulerTaskLogRow> logs;
  final ErrandDatabase db;
  final VoidCallback onViewLogs;
  final VoidCallback? onEditModel;

  const SpaceyTaskRow({
    super.key,
    required this.task,
    required this.logs,
    required this.db,
    required this.onViewLogs,
    this.onEditModel,
  });

  @override
  State<SpaceyTaskRow> createState() => _SpaceyTaskRowState();
}

class _SpaceyTaskRowState extends State<SpaceyTaskRow> {
  bool _executing = false;
  StreamSubscription<TaskProgressEvent>? _progressSub;

  bool get _isRunning => widget.task.status == 'running' || _executing;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _progressSub = TaskProgressService.instance.stream.listen((event) {
        if (event.taskId == widget.task.id && mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final statusColor = _getStatusColor(task.status);
    final isRecurring = task.type == 'recurring';

    // Logs action button color based on last execution status
    Color logsIconColor = kMuted;
    String logsTooltip = 'View Logs & Output';
    if (task.totalRuns > 0 || widget.logs.isNotEmpty) {
      final lastLog = widget.logs.cast<SchedulerTaskLogRow?>().firstWhere(
            (l) => l != null && l.status != 'running',
            orElse: () => null,
          );
      if (lastLog != null) {
        if (lastLog.status == 'success') {
          logsIconColor = Colors.greenAccent;
          logsTooltip = 'View Logs & Output (Last run succeeded)';
        } else if (lastLog.status == 'failed') {
          logsIconColor = kDanger;
          logsTooltip = 'View Logs & Output (Last run failed)';
        } else if (lastLog.status == 'timeout') {
          logsIconColor = Colors.orangeAccent;
          logsTooltip = 'View Logs & Output (Last run timed out)';
        }
      }
    }


    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Status indicator + Type + Model + ID
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                  boxShadow: _isRunning
                      ? [
                          BoxShadow(
                            color: Colors.amberAccent.withValues(alpha: 0.6),
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                task.status.toUpperCase(),
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    isRecurring ? Icons.repeat_rounded : Icons.bolt_rounded,
                    size: 11,
                    color: kMuted,
                  ),
                  const SizedBox(width: 3.5),
                  Padding(
                    padding: const EdgeInsets.only(top: 1.0),
                    child: Text(
                      isRecurring ? 'RECURRING' : 'ONE-OFF',
                      style: const TextStyle(
                        color: kMuted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '#${task.id}',
                style: const TextStyle(
                  color: kMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Row 2: Title
          Text(
            task.title,
            style: const TextStyle(
              color: kText,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 5),

          // Row 3: Timing Info
          TaskTimingInfo(task: task),
          if (_isRunning && kDebugMode) ...[
            const SizedBox(height: 6),
            _DebugTaskLiveProgress(taskId: task.id),
          ],
          const SizedBox(height: 6),

          // Row 4: Stats + Action buttons
          // Actions are gated by status: terminal states (completed/failed/
          // cancelled) expose no pause or re-run; paused/cancelled expose no
          // run (the allowlist would reject it); pause toggles scheduled only.
          Row(
            children: [
              Expanded(
                child: Text(
                  'Runs: ${task.totalRuns}',
                  style: const TextStyle(color: kMuted, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),

              // Cancel button if running (Skip for recurring: series survives)
              if (_isRunning) ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kDanger,
                    side: BorderSide(color: kDanger.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: const Size(0, 26),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _cancelExecution(task),
                  icon: const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: kDanger),
                  ),
                  label: Text(
                    task.type == 'recurring' ? 'Skip' : 'Cancel',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ] else ...[
                if (task.status == 'scheduled' ||
                    task.status == 'failed' ||
                    task.status == 'completed') ...[
                  TaskActionButton(
                    icon: Icons.play_arrow_rounded,
                    tooltip: 'Run Now (test trigger)',
                    color: Colors.greenAccent,
                    onTap: () => _runNow(context, task.id),
                  ),
                  const SizedBox(width: 3),
                ],
                if (task.status == 'scheduled' || task.status == 'paused')
                  TaskActionButton(
                    icon: task.status == 'paused'
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    tooltip: task.status == 'paused' ? 'Resume Task' : 'Pause Task',
                    color: kMuted,
                    onTap: () => _togglePause(task),
                  ),
              ],
              if (widget.onEditModel != null) ...[
                const SizedBox(width: 3),
                TaskActionButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'Edit Task Settings',
                  color: kMuted,
                  onTap: widget.onEditModel,
                ),
              ],
              const SizedBox(width: 3),
              TaskActionButton(
                icon: Icons.receipt_long_rounded,
                tooltip: logsTooltip,
                color: logsIconColor,
                onTap: widget.onViewLogs,
              ),
              const SizedBox(width: 3),
              TaskActionButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Delete Task',
                color: kDanger,
                onTap: () => _deleteTask(task.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'scheduled':
        return Colors.lightBlueAccent;
      case 'running':
        return Colors.amberAccent;
      case 'completed':
        return Colors.greenAccent;
      case 'failed':
        return kDanger;
      case 'paused':
      case 'cancelled':
      default:
        return kMuted;
    }
  }

  Future<void> _runNow(BuildContext context, int taskId) async {
    setState(() => _executing = true);
    try {
      final success = await TaskSchedulerService.instance.executeTask(
        taskId,
        allowCompleted: true,
        suppressNotification: true,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'Task #$taskId completed!' : 'Task #$taskId failed.'),
            backgroundColor: success ? Colors.green : kDanger,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error running task: $e'),
            backgroundColor: kDanger,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _executing = false);
      }
    }
  }

  Future<void> _cancelExecution(SchedulerTaskRow task) async {
    final isSeries = task.type == 'recurring';
    if (isSeries) {
      await TaskSchedulerService.instance.skipCurrentRun(task.id);
    } else {
      await TaskSchedulerService.instance.cancelRunningTask(task.id);
    }
    if (mounted) {
      setState(() => _executing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isSeries
                ? 'Task #${task.id} run skipped — series continues'
                : 'Task #${task.id} cancelled',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: kDanger,
        ),
      );
    }
  }

  Future<void> _togglePause(SchedulerTaskRow task) async {
    final db = widget.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (task.status == 'paused') {
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(task.id))).write(
        SchedulerTasksCompanion(
          status: const Value('scheduled'),
          updatedAt: Value(now),
        ),
      );
      await TaskSchedulerService.instance.scheduleTask(task.id);
    } else {
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(task.id))).write(
        SchedulerTasksCompanion(
          status: const Value('paused'),
          updatedAt: Value(now),
        ),
      );
      await TaskSchedulerService.instance.cancelTask(task.id);
    }
  }

  Future<void> _deleteTask(int taskId) async {
    final stats = await TaskSchedulerService.instance.getTaskFileStats(taskId);
    if (!mounted) return;

    var deleteFiles = stats.count > 0;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bytesStr = _formatBytes(stats.bytes);
            return AlertDialog(
              backgroundColor: const Color(0xFF1E222B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: const Text('Delete Task?', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Are you sure you want to delete "${widget.task.title}"?',
                    style: const TextStyle(color: Color(0xFFC9D1D9), fontSize: 14),
                  ),
                  if (stats.count > 0) ...[
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: () => setDialogState(() => deleteFiles = !deleteFiles),
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        children: [
                          Checkbox(
                            value: deleteFiles,
                            onChanged: (val) => setDialogState(() => deleteFiles = val ?? false),
                            activeColor: kBubbleUser,
                          ),
                          Expanded(
                            child: Text(
                              'Also delete ${stats.count} report ${stats.count == 1 ? 'file' : 'files'} ($bytesStr)?',
                              style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(false),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF8B949E))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(true),
                  child: const Text('Delete', style: TextStyle(color: kDanger, fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirm != true || !mounted) return;

    final deleted = await TaskSchedulerService.instance.deleteTask(
      taskId,
      deleteFiles: deleteFiles,
    );
    if (!deleted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task not found — already deleted')),
      );
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _DebugTaskLiveProgress extends StatefulWidget {
  final int taskId;
  const _DebugTaskLiveProgress({required this.taskId});

  @override
  State<_DebugTaskLiveProgress> createState() => _DebugTaskLiveProgressState();
}

class _DebugTaskLiveProgressState extends State<_DebugTaskLiveProgress> {
  bool _expanded = false;
  bool _copied = false;
  Timer? _copyTimer;

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  String _formatTraceForClipboard(List<TaskProgressEvent> history) {
    final buffer = StringBuffer();
    buffer.writeln('=== Task #${widget.taskId} Debug Trace ===');
    for (var i = 0; i < history.length; i++) {
      final ev = history[i];
      final time =
          '${ev.timestamp.hour.toString().padLeft(2, '0')}:${ev.timestamp.minute.toString().padLeft(2, '0')}:${ev.timestamp.second.toString().padLeft(2, '0')}';
      buffer.writeln('[$time] [Step ${i + 1}] [Turn ${ev.turn}] [${ev.stageLabel}] ${ev.message}');
      if (ev.toolArgs != null && ev.toolArgs!.isNotEmpty) {
        buffer.writeln('  Arguments: ${ev.toolArgs}');
      }
      if (ev.toolResultSnippet != null && ev.toolResultSnippet!.isNotEmpty) {
        buffer.writeln('  Result: ${ev.toolResultSnippet}');
      }
    }
    return buffer.toString().trim();
  }

  void _copyTrace(List<TaskProgressEvent> history) {
    if (history.isEmpty) return;
    final text = _formatTraceForClipboard(history);
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${history.length} trace step${history.length == 1 ? '' : 's'} to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final latest = TaskProgressService.instance.getLatest(widget.taskId);
    final history = TaskProgressService.instance.getHistory(widget.taskId);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.greenAccent,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'DEBUG LIVE WATCH',
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (latest != null)
                Text(
                  'Turn ${latest.turn} • ${latest.stageLabel}',
                  style: const TextStyle(color: kMuted, fontSize: 9.5),
                ),
              if (history.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _copyTrace(history),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 11,
                          color: _copied ? Colors.greenAccent : Colors.cyanAccent,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          _copied ? 'Copied' : 'Copy Trace',
                          style: TextStyle(
                            color: _copied ? Colors.greenAccent : Colors.cyanAccent,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Current step info
          if (latest != null) ...[
            Text(
              latest.message,
              style: TextStyle(
                color: latest.isError ? Colors.redAccent : Colors.white,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            if (latest.toolArgs != null && latest.toolArgs!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                'args: ${latest.toolArgs}',
                style: const TextStyle(color: kMuted, fontSize: 10, fontFamily: 'monospace'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ] else ...[
            const Row(
              children: [
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.cyanAccent),
                ),
                SizedBox(width: 6),
                Text(
                  'Waiting for task updates...',
                  style: TextStyle(color: kMuted, fontSize: 11),
                ),
              ],
            ),
          ],
          if (history.length > 1) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 14,
                    color: Colors.cyanAccent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expanded ? 'Hide trace' : 'Show trace (${history.length} steps)',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 4),
              const Divider(color: Color(0xFF30363D), height: 8),
              ...history.reversed.map((ev) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[T${ev.turn}] ',
                        style: const TextStyle(color: kMuted, fontSize: 9.5, fontFamily: 'monospace'),
                      ),
                      Expanded(
                        child: Text(
                          ev.message,
                          style: TextStyle(
                            color: ev.isError ? Colors.redAccent : const Color(0xFFC9D1D9),
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ],
      ),
    );
  }
}
