import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../screens/task_file_preview_screen.dart';
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
  final TaskSchedulerService? scheduler;

  const SpaceyTaskRow({
    super.key,
    required this.task,
    required this.logs,
    required this.db,
    required this.onViewLogs,
    this.onEditModel,
    this.scheduler,
  });

  @override
  State<SpaceyTaskRow> createState() => _SpaceyTaskRowState();
}

class _SpaceyTaskRowState extends State<SpaceyTaskRow> {
  TaskSchedulerService get _scheduler => widget.scheduler ?? TaskSchedulerService.instance;
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
    final List<File> files = await _scheduler.getOwnedFilesForTask(taskId);
    if (!mounted) return;

    var totalBytes = 0;
    for (final f in files) {
      try {
        totalBytes += f.lengthSync();
      } catch (_) {}
    }

    var deleteFiles = files.isNotEmpty;
    var filesExpanded = false;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bytesStr = _formatBytes(totalBytes);
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
                  if (files.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: deleteFiles,
                                onChanged: (val) => setDialogState(() => deleteFiles = val ?? false),
                                activeColor: kBubbleUser,
                              ),
                              Expanded(
                                child: InkWell(
                                  onTap: () => setDialogState(() => deleteFiles = !deleteFiles),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Text(
                                      'Also delete ${files.length} report ${files.length == 1 ? 'file' : 'files'} ($bytesStr)?',
                                      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
                                    ),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => setDialogState(() => filesExpanded = !filesExpanded),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    filesExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                    color: const Color(0xFF8B949E),
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (filesExpanded) ...[
                            const Divider(height: 1, color: Color(0xFF30363D)),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: Scrollbar(
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: files.length,
                                  separatorBuilder: (context, index) => const Divider(
                                    height: 1,
                                    color: Color(0xFF21262D),
                                  ),
                                  itemBuilder: (context, index) {
                                    final file = files[index];
                                    final relPath = TaskSchedulerService.toScratchRelative(file.path);
                                    int fileBytes = 0;
                                    try {
                                      fileBytes = file.existsSync() ? file.lengthSync() : 0;
                                    } catch (_) {}
                                    return InkWell(
                                      onTap: () {
                                        TaskFilePreviewScreen.show(
                                          dialogCtx,
                                          filePath: file.path,
                                          title: p.basename(file.path),
                                        );
                                      },
                                      borderRadius: BorderRadius.circular(4),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                        child: Row(
                                          children: [
                                            Icon(
                                              _iconForPath(relPath),
                                              color: const Color(0xFF58A6FF),
                                              size: 14,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                relPath,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Color(0xFF58A6FF),
                                                  fontSize: 12,
                                                  decoration: TextDecoration.underline,
                                                  decorationColor: Color(0xFF58A6FF),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _formatBytes(fileBytes),
                                              style: const TextStyle(
                                                color: Color(0xFF8B949E),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
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

    final deleted = await _scheduler.deleteTask(
      taskId,
      deleteFiles: deleteFiles,
    );
    if (!deleted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task not found — already deleted')),
      );
    }
  }

  static IconData _iconForPath(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.md':
      case '.txt':
        return Icons.description_outlined;
      case '.html':
      case '.htm':
        return Icons.html_rounded;
      case '.csv':
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
      default:
        return Icons.insert_drive_file_outlined;
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
