import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';

import '../services/database.dart';
import '../services/task_scheduler_service.dart';
import '../theme/app_colors.dart';

/// Opens the temporary testing modal bottom sheet to inspect, run, and manage scheduled tasks.
Future<void> showTasksSheet(BuildContext context, {ErrandDatabase? database}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: kInputBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => TasksSheet(database: database),
  );
}

class TasksSheet extends StatelessWidget {
  final ErrandDatabase db;

  TasksSheet({super.key, ErrandDatabase? database})
      : db = database ?? ErrandDatabase.instance;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Scheduled Tasks',
                          style: TextStyle(
                            color: kText,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Autonomous background engine inspection',
                          style: TextStyle(color: kMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kText,
                      side: const BorderSide(color: kBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _createTestTask(context, db),
                    icon: const Icon(Icons.alarm_add_rounded, size: 16),
                    label: const Text(
                      '+ Test (10s)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: kBorder, height: 1),
            FutureBuilder<bool>(
              future: TaskSchedulerService.instance.canScheduleExactAlarms(),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data == false) {
                  return Container(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Exact alarms not permitted. Tasks may be delayed by battery optimization.',
                            style: TextStyle(color: Colors.amber, fontSize: 11),
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => TaskSchedulerService.instance.openExactAlarmSettings(),
                          child: const Text(
                            'Enable',
                            style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            Expanded(
              child: StreamBuilder<List<SchedulerTaskRow>>(
                stream: (db.select(db.schedulerTasks)
                      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
                    .watch(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                    return const SizedBox.shrink();
                  }

                  final tasks = snapshot.data ?? [];
                  if (tasks.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule_rounded, color: kMuted, size: 40),
                            const SizedBox(height: 12),
                            const Text(
                              'No scheduled tasks yet',
                              style: TextStyle(
                                color: kText,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Tap "+ Test (10s)" to create a quick test task or ask Errand to schedule one.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: kMuted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return _TaskCard(task: task, db: db);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createTestTask(BuildContext context, ErrandDatabase db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final triggerAt = now + 10000; // 10 seconds in future

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Test alarm task',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({
          'prompt':
              'This is a quick test turn. Output a short 2-line summary confirming background execution.',
        }),
        startsAt: triggerAt,
        notify: const Value(true),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await TaskSchedulerService.instance.scheduleTask(taskId);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Test task #$taskId scheduled to fire in 10s!'),
          backgroundColor: kBubbleUser,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

class _TaskCard extends StatefulWidget {
  final SchedulerTaskRow task;
  final ErrandDatabase db;

  const _TaskCard({required this.task, required this.db});

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _executing = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final statusColor = _getStatusColor(task.status);

    return Container(
      decoration: BoxDecoration(
        color: kBubbleAssistant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  task.status.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: kBorder.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  task.type == 'recurring' ? 'RECURRING' : 'ONE-OFF',
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
          const SizedBox(height: 8),
          Text(
            task.title,
            style: const TextStyle(
              color: kText,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          _buildTimingInfo(task),
          const SizedBox(height: 10),
          const Divider(color: kBorder, height: 1),
          const SizedBox(height: 6),
          Row(
            children: [
              StreamBuilder<List<SchedulerTaskLogRow>>(
                stream: (widget.db.select(widget.db.schedulerTaskLogs)
                      ..where((l) => l.schedulerTaskId.equals(task.id)))
                    .watch(),
                builder: (context, snapshot) {
                  final logs = snapshot.data;
                  if (logs == null) {
                    return Text(
                      'Runs: ${task.totalRuns}',
                      style: const TextStyle(color: kMuted, fontSize: 11),
                    );
                  }
                  final successes = logs.where((l) => l.status == 'success').length;
                  final fails = logs
                      .where((l) => l.status == 'failed' || l.status == 'timeout')
                      .length;
                  return Text(
                    'Runs: ${task.totalRuns} • Success: $successes • Fails: $fails',
                    style: const TextStyle(color: kMuted, fontSize: 11),
                  );
                },
              ),
              const Spacer(),
              if (_executing)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else ...[
                IconButton(
                  tooltip: 'Run Now (test trigger)',
                  icon: const Icon(Icons.play_arrow_rounded, color: Colors.greenAccent, size: 20),
                  onPressed: () => _runNow(context, task.id),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: task.status == 'paused' ? 'Resume Task' : 'Pause Task',
                  icon: Icon(
                    task.status == 'paused'
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    color: kMuted,
                    size: 20,
                  ),
                  onPressed: () => _togglePause(task),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: 'View Logs & Output',
                  icon: const Icon(Icons.receipt_long_rounded, color: kMuted, size: 20),
                  onPressed: () => _showLogs(context, task),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: 'Delete Task',
                  icon: const Icon(Icons.delete_outline_rounded, color: kDanger, size: 20),
                  onPressed: () => _deleteTask(task.id),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimingInfo(SchedulerTaskRow task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRun = task.nextRunAt ?? task.startsAt;
    final diff = nextRun - now;

    String timingText;
    if (diff > 0) {
      final secs = diff ~/ 1000;
      if (secs < 60) {
        timingText = 'Fires in ${secs}s';
      } else if (secs < 3600) {
        timingText = 'Fires in ${secs ~/ 60}m ${secs % 60}s';
      } else {
        final hours = secs ~/ 3600;
        final mins = (secs % 3600) ~/ 60;
        timingText = 'Fires in ${hours}h ${mins}m';
      }
    } else {
      timingText = 'Scheduled time reached';
    }

    if (task.type == 'recurring' && task.repeatAfter != null) {
      final intervalMin = task.repeatAfter! ~/ 60000;
      timingText += ' (repeats every ${intervalMin}m)';
    }

    return Text(
      timingText,
      style: const TextStyle(color: kMuted, fontSize: 12),
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
      default:
        return kMuted;
    }
  }

  Future<void> _runNow(BuildContext context, int taskId) async {
    setState(() => _executing = true);
    try {
      final success = await TaskSchedulerService.instance.executeTask(taskId);
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
    await TaskSchedulerService.instance.cancelTask(taskId);
    final db = widget.db;
    await (db.delete(db.schedulerTasks)..where((t) => t.id.equals(taskId))).go();
  }

  void _showLogs(BuildContext context, SchedulerTaskRow task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kInputBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _TaskLogsSheet(
        taskId: task.id,
        taskTitle: task.title,
        db: widget.db,
      ),
    );
  }
}

class _TaskLogsSheet extends StatelessWidget {
  final int taskId;
  final String taskTitle;
  final ErrandDatabase db;

  const _TaskLogsSheet({
    required this.taskId,
    required this.taskTitle,
    required this.db,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Execution Logs • #$taskId',
                    style: const TextStyle(
                      color: kText,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    taskTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Divider(color: kBorder, height: 1),
            Expanded(
              child: StreamBuilder<List<SchedulerTaskLogRow>>(
                stream: (db.select(db.schedulerTaskLogs)
                      ..where((l) => l.schedulerTaskId.equals(taskId))
                      ..orderBy([(l) => OrderingTerm.desc(l.createdAt)]))
                    .watch(),
                builder: (context, snapshot) {
                  final logs = snapshot.data ?? [];
                  if (logs.isEmpty) {
                    return const Center(
                      child: Text(
                        'No run logs recorded yet.',
                        style: TextStyle(color: kMuted, fontSize: 13),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      final isSuccess = log.status == 'success';
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kBubbleAssistant,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: kBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isSuccess
                                      ? Icons.check_circle_rounded
                                      : Icons.error_outline_rounded,
                                  color: isSuccess ? Colors.greenAccent : kDanger,
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  log.status.toUpperCase(),
                                  style: TextStyle(
                                    color: isSuccess ? Colors.greenAccent : kDanger,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatTime(log.startedAt ?? log.createdAt),
                                  style: const TextStyle(color: kMuted, fontSize: 11),
                                ),
                              ],
                            ),
                            if (log.summary != null && log.summary!.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                log.summary!,
                                style: const TextStyle(color: kText, fontSize: 12),
                              ),
                            ],
                            if (log.errorMessage != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Error: ${log.errorMessage}',
                                style: const TextStyle(color: kDanger, fontSize: 11),
                              ),
                            ],
                            if (log.outputFilePath != null) ...[
                              const SizedBox(height: 6),
                              InkWell(
                                onTap: () => _viewReport(context, log.outputFilePath!),
                                child: Row(
                                  children: [
                                    const Icon(Icons.description_outlined, color: kBubbleUser, size: 14),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        log.outputFilePath!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: kBubbleUser,
                                          fontSize: 11,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  void _viewReport(BuildContext context, String path) async {
    final file = File(path);
    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      content = 'Failed to read file: $e';
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kInputBg,
        title: const Text('Task Report', style: TextStyle(color: kText, fontSize: 16)),
        content: SingleChildScrollView(
          child: Text(
            content,
            style: const TextStyle(color: kText, fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
