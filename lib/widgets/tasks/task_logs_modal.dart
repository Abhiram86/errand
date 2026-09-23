import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../services/database.dart';
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
