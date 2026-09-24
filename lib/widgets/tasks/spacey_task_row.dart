import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../services/database.dart';
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

  bool get _isRunning => widget.task.status == 'running' || _executing;

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
    final deleted = await TaskSchedulerService.instance.deleteTask(taskId);
    if (!deleted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task not found — already deleted')),
      );
    }
  }
}
