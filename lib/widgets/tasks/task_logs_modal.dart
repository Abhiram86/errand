import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../services/database.dart';
import '../../services/task_scheduler_service.dart';
import '../../theme/app_colors.dart';
import 'spacey_log_item.dart';

/// Task Logs Modal (Bottom sheet for task-specific logs).
class TaskLogsModal extends StatelessWidget {
  final int taskId;
  final String taskTitle;
  final ErrandDatabase db;

  const TaskLogsModal({
    super.key,
    required this.taskId,
    required this.taskTitle,
    required this.db,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Execution Logs • #$taskId',
                          style: const TextStyle(
                            color: kText,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          taskTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  _ClearLogsButton(
                    taskId: taskId,
                    taskTitle: taskTitle,
                    db: db,
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
                        style: TextStyle(color: kMuted, fontSize: 12),
                      ),
                    );
                  }

                  final succeeded =
                      logs.where((l) => l.status == 'success').length;
                  final failed = logs
                      .where((l) =>
                          l.status == 'failed' || l.status == 'timeout')
                      .length;

                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Row(
                          children: [
                            LogStatChip(
                              value: '${logs.length}',
                              label: 'runs',
                              color: kMuted,
                            ),
                            const SizedBox(width: 8),
                            LogStatChip(
                              value: '$succeeded',
                              label: 'succeeded',
                              color: Colors.greenAccent,
                            ),
                            const SizedBox(width: 8),
                            LogStatChip(
                              value: '$failed',
                              label: 'failed',
                              color: kDanger,
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: kBorder, height: 1),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: logs.length,
                          separatorBuilder: (_, _) => Divider(
                              color: kBorder.withValues(alpha: 0.35), height: 1),
                          itemBuilder: (context, index) {
                            final log = logs[index];
                            return SpaceyLogItem(
                              log: log,
                              task: null,
                              onMarkSeen: () async {
                                final now =
                                    DateTime.now().millisecondsSinceEpoch;
                                await (db.update(db.schedulerTaskLogs)
                                      ..where((l) =>
                                          l.id.equals(log.id)))
                                    .write(
                                  SchedulerTaskLogsCompanion(
                                    notificationSeen: const Value(1),
                                    updatedAt: Value(now),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClearLogsButton extends StatelessWidget {
  final int taskId;
  final String taskTitle;
  final ErrandDatabase db;

  const _ClearLogsButton({
    required this.taskId,
    required this.taskTitle,
    required this.db,
  });

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _handleClear(BuildContext context) async {
    final scheduler = TaskSchedulerService.instance;
    final files = await scheduler.getOwnedFilesForTask(taskId);
    if (!context.mounted) return;

    var totalBytes = 0;
    for (final f in files) {
      try {
        totalBytes += f.lengthSync();
      } catch (_) {}
    }

    var deleteFiles = files.isNotEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bytesStr = _formatBytes(totalBytes);
            return AlertDialog(
              backgroundColor: const Color(0xFF1E222B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: const Text(
                'Clear Logs & Files?',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Are you sure you want to clear all execution logs for "$taskTitle"?',
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
                      child: Row(
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
                                  'Also delete output & linked files (${files.length} file${files.length == 1 ? '' : 's'}, $bytesStr)',
                                  style: const TextStyle(color: Color(0xFFC9D1D9), fontSize: 12),
                                ),
                              ),
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
                  child: const Text('Clear', style: TextStyle(color: kDanger, fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && context.mounted) {
      await scheduler.deleteLogsForTask(taskId, deleteFiles: deleteFiles);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleteFiles ? 'Cleared logs and deleted associated files' : 'Cleared execution logs',
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SchedulerTaskLogRow>>(
      stream: (db.select(db.schedulerTaskLogs)
            ..where((l) => l.schedulerTaskId.equals(taskId)))
          .watch(),
      builder: (context, snapshot) {
        final hasLogs = (snapshot.data ?? []).isNotEmpty;
        if (!hasLogs) return const SizedBox.shrink();

        return InkWell(
          onTap: () => _handleClear(context),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.delete_sweep_outlined, size: 16, color: kDanger),
                SizedBox(width: 4),
                Text(
                  'Clear',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: kDanger,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
