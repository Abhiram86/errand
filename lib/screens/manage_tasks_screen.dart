import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/database.dart';
import '../services/task_scheduler_service.dart';
import '../theme/app_colors.dart';
import 'task_file_preview_screen.dart';

/// Full-screen management page for scheduled tasks, logs, and autonomous background runs.
class ManageTasksScreen extends StatefulWidget {
  final ErrandDatabase? database;

  const ManageTasksScreen({super.key, this.database});

  @override
  State<ManageTasksScreen> createState() => _ManageTasksScreenState();
}

class _ManageTasksScreenState extends State<ManageTasksScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final ErrandDatabase _db;

  // Filters for Upcoming Tab
  String _upcomingTypeFilter = 'all'; // 'all', 'one_off', 'recurring'

  // Filters for Unread Tab
  String _unreadScopeFilter = 'unread'; // 'unread', 'all'

  // Filters for All Tasks Tab
  String _allStatusFilter = 'all'; // 'all', 'active', 'paused', 'completed', 'failed', 'cancelled'
  String _allTypeFilter = 'all'; // 'all', 'recurring', 'one_off'

  late final Future<bool> _exactAlarmsFuture;
  late final Stream<List<SchedulerTaskRow>> _tasksStream;
  late final Stream<List<SchedulerTaskLogRow>> _logsStream;

  @override
  void initState() {
    super.initState();
    _db = widget.database ?? ErrandDatabase.instance;
    _tasksStream = (_db.select(_db.schedulerTasks)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
    _logsStream = (_db.select(_db.schedulerTaskLogs)
          ..orderBy([(l) => OrderingTerm.desc(l.createdAt)]))
        .watch();
    _tabController = TabController(length: 3, vsync: this);
    _exactAlarmsFuture = TaskSchedulerService.instance.canScheduleExactAlarms();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SchedulerTaskRow>>(
      stream: _tasksStream,
      builder: (context, taskSnapshot) {
        final allTasks = taskSnapshot.data ?? [];

        return StreamBuilder<List<SchedulerTaskLogRow>>(
          stream: _logsStream,
          builder: (context, logSnapshot) {
            final allLogs = logSnapshot.data ?? [];

            final upcomingTasks = allTasks.where((t) {
              if (t.status == 'running') return true;
              if (t.status != 'scheduled') return false;
              return true;
            }).toList();

            final unreadLogs = allLogs.where((l) => l.notificationSeen == 0).toList();

            return Scaffold(
              backgroundColor: kDarkBg,
              appBar: AppBar(
                backgroundColor: kInputBg,
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: kText),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                title: const Text(
                  'Manage Tasks',
                  style: TextStyle(
                    color: kText,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.alarm_add_rounded, color: kBubbleUser, size: 22),
                    tooltip: '+ Test task (10s)',
                    onPressed: _createTestTask,
                  ),
                  const SizedBox(width: 4),
                ],
                bottom: TabBar(
                  controller: _tabController,
                  indicatorColor: kBubbleUser,
                  indicatorWeight: 2.5,
                  dividerColor: Colors.transparent,
                  dividerHeight: 0,
                  labelColor: kText,
                  unselectedLabelColor: kMuted,
                  labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      tabs: [
                        Tab(
                          child: _buildTabLabel(
                            title: 'Upcoming',
                            count: upcomingTasks.length,
                            highlight: upcomingTasks.any((t) => t.status == 'running'),
                          ),
                        ),
                        Tab(
                          child: _buildTabLabel(
                            title: 'Unread',
                            count: unreadLogs.length,
                            highlight: unreadLogs.isNotEmpty,
                          ),
                        ),
                        Tab(
                          child: _buildTabLabel(
                            title: 'All Tasks',
                            count: allTasks.length,
                          ),
                        ),
                      ],
                    ),
                  ),
              body: Column(
                children: [
                  _buildExactAlarmWarning(),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildUpcomingTab(upcomingTasks, allLogs),
                        _buildUnreadTab(allLogs, allTasks),
                        _buildAllTasksTab(allTasks, allLogs),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTabLabel({
    required String title,
    required int count,
    bool highlight = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count > 0) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: highlight
                  ? Colors.amber.withValues(alpha: 0.2)
                  : kBorder.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: highlight ? Colors.amberAccent : kMuted,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExactAlarmWarning() {
    return FutureBuilder<bool>(
      future: _exactAlarmsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data == false) {
          return Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Exact alarms not permitted. Tasks may be delayed by system battery optimization.',
                    style: TextStyle(color: Colors.amber, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 6),
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
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Upcoming Tasks
  // ---------------------------------------------------------------------------

  Widget _buildUpcomingTab(List<SchedulerTaskRow> tasks, List<SchedulerTaskLogRow> logs) {
    final filtered = tasks.where((t) {
      if (_upcomingTypeFilter != 'all' && t.type != _upcomingTypeFilter) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        _buildFilterBar(
          children: [
            _buildChoiceChip(
              label: 'All (${tasks.length})',
              selected: _upcomingTypeFilter == 'all',
              onSelected: () => setState(() => _upcomingTypeFilter = 'all'),
            ),
            _buildChoiceChip(
              label: 'Recurring',
              selected: _upcomingTypeFilter == 'recurring',
              onSelected: () => setState(() => _upcomingTypeFilter = 'recurring'),
            ),
            _buildChoiceChip(
              label: 'One-off',
              selected: _upcomingTypeFilter == 'one_off',
              onSelected: () => setState(() => _upcomingTypeFilter = 'one_off'),
            ),
          ],
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  icon: Icons.event_available_rounded,
                  title: 'No upcoming tasks',
                  subtitle: tasks.isEmpty
                      ? 'No tasks are currently scheduled to run. Tap the clock icon above to test.'
                      : 'No tasks match the selected filter.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    final task = filtered[index];
                    final taskLogs = logs.where((l) => l.schedulerTaskId == task.id).toList();
                    return _SpaceyTaskRow(
                      task: task,
                      logs: taskLogs,
                      db: _db,
                      onViewLogs: () => _openTaskLogs(task),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2: Unread (Task Logs)
  // ---------------------------------------------------------------------------

  Widget _buildUnreadTab(List<SchedulerTaskLogRow> allLogs, List<SchedulerTaskRow> tasks) {
    final taskMap = {for (final t in tasks) t.id: t};

    final filtered = allLogs.where((l) {
      if (_unreadScopeFilter == 'unread' && l.notificationSeen != 0) {
        return false;
      }
      return true;
    }).toList();

    final unreadCount = allLogs.where((l) => l.notificationSeen == 0).length;

    return Column(
      children: [
        _buildFilterBar(
          trailing: unreadCount > 0
              ? OutlinedButton.icon(
                  onPressed: _markAllLogsAsRead,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBubbleUser,
                    side: BorderSide(color: kBubbleUser.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: const Size(0, 26),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.done_all_rounded, size: 13),
                  label: const Text(
                    'Mark all read',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                )
              : null,
          children: [
            _buildChoiceChip(
              label: 'Unread ($unreadCount)',
              selected: _unreadScopeFilter == 'unread',
              onSelected: () => setState(() => _unreadScopeFilter = 'unread'),
            ),
            _buildChoiceChip(
              label: 'All logs (${allLogs.length})',
              selected: _unreadScopeFilter == 'all',
              onSelected: () => setState(() => _unreadScopeFilter = 'all'),
            ),
          ],
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  icon: Icons.mark_email_read_rounded,
                  title: _unreadScopeFilter == 'unread' ? 'All caught up!' : 'No task logs',
                  subtitle: _unreadScopeFilter == 'unread'
                      ? 'No unread execution logs. Switch to "All logs" to review past runs.'
                      : 'No execution logs recorded yet.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    final log = filtered[index];
                    final task = taskMap[log.schedulerTaskId];
                    return _SpaceyLogItem(
                      log: log,
                      task: task,
                      onMarkSeen: () => _markLogSeen(log.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 3: All Tasks
  // ---------------------------------------------------------------------------

  Widget _buildAllTasksTab(List<SchedulerTaskRow> tasks, List<SchedulerTaskLogRow> logs) {
    final filtered = tasks.where((t) {
      if (_allStatusFilter == 'active') {
        if (t.status != 'scheduled' && t.status != 'running') return false;
      } else if (_allStatusFilter != 'all' && t.status != _allStatusFilter) {
        return false;
      }

      if (_allTypeFilter != 'all' && t.type != _allTypeFilter) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        _buildFilterBar(
          children: [
            _buildChoiceChip(
              label: 'All (${tasks.length})',
              selected: _allStatusFilter == 'all' && _allTypeFilter == 'all',
              onSelected: () => setState(() {
                _allStatusFilter = 'all';
                _allTypeFilter = 'all';
              }),
            ),
            _buildChoiceChip(
              label: 'Active',
              selected: _allStatusFilter == 'active',
              onSelected: () => setState(() => _allStatusFilter = _allStatusFilter == 'active' ? 'all' : 'active'),
            ),
            _buildChoiceChip(
              label: 'Paused',
              selected: _allStatusFilter == 'paused',
              onSelected: () => setState(() => _allStatusFilter = _allStatusFilter == 'paused' ? 'all' : 'paused'),
            ),
            _buildChoiceChip(
              label: 'Completed',
              selected: _allStatusFilter == 'completed',
              onSelected: () => setState(() => _allStatusFilter = _allStatusFilter == 'completed' ? 'all' : 'completed'),
            ),
            _buildChoiceChip(
              label: 'Failed',
              selected: _allStatusFilter == 'failed',
              onSelected: () => setState(() => _allStatusFilter = _allStatusFilter == 'failed' ? 'all' : 'failed'),
            ),
            _buildChoiceChip(
              label: 'Recurring',
              selected: _allTypeFilter == 'recurring',
              onSelected: () => setState(() => _allTypeFilter = _allTypeFilter == 'recurring' ? 'all' : 'recurring'),
            ),
            _buildChoiceChip(
              label: 'One-off',
              selected: _allTypeFilter == 'one_off',
              onSelected: () => setState(() => _allTypeFilter = _allTypeFilter == 'one_off' ? 'all' : 'one_off'),
            ),
          ],
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  icon: Icons.checklist_rounded,
                  title: 'No tasks found',
                  subtitle: tasks.isEmpty
                      ? 'No tasks created yet. Ask Errand to schedule something or tap the clock icon.'
                      : 'No tasks match the active filters.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    final task = filtered[index];
                    final taskLogs = logs.where((l) => l.schedulerTaskId == task.id).toList();
                    return _SpaceyTaskRow(
                      task: task,
                      logs: taskLogs,
                      db: _db,
                      onViewLogs: () => _openTaskLogs(task),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers & Actions
  // ---------------------------------------------------------------------------

  Widget _buildFilterBar({required List<Widget> children, Widget? trailing}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: kInputBg.withValues(alpha: 0.4),
        border: const Border(bottom: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...children,
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? kBubbleUser.withValues(alpha: 0.22) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? kBubbleUser.withValues(alpha: 0.6) : kBorder.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kText : kMuted,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kMuted.withValues(alpha: 0.5), size: 44),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: kText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kMuted, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createTestTask() async {
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now().millisecondsSinceEpoch;
    final triggerAt = now + 10000;

    final taskId = await _db.into(_db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Test background run',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({
          'prompt':
              'Confirm background run in markdown format with a bulleted list.',
        }),
        startsAt: triggerAt,
        notify: const Value(true),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await TaskSchedulerService.instance.scheduleTask(taskId);

    if (mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Test task #$taskId scheduled to fire in 10s!'),
          backgroundColor: kBubbleUser,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _markLogSeen(int logId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
      SchedulerTaskLogsCompanion(
        notificationSeen: const Value(1),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> _markAllLogsAsRead() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.schedulerTaskLogs)..where((l) => l.notificationSeen.equals(0))).write(
      SchedulerTaskLogsCompanion(
        notificationSeen: const Value(1),
        updatedAt: Value(now),
      ),
    );
  }

  void _openTaskLogs(SchedulerTaskRow task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kInputBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _TaskLogsModal(
        taskId: task.id,
        taskTitle: task.title,
        db: _db,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Spacey, Less-Cardy Task Row Widget
// ---------------------------------------------------------------------------

class _SpaceyTaskRow extends StatefulWidget {
  final SchedulerTaskRow task;
  final List<SchedulerTaskLogRow> logs;
  final ErrandDatabase db;
  final VoidCallback onViewLogs;

  const _SpaceyTaskRow({
    required this.task,
    required this.logs,
    required this.db,
    required this.onViewLogs,
  });

  @override
  State<_SpaceyTaskRow> createState() => _SpaceyTaskRowState();
}

class _SpaceyTaskRowState extends State<_SpaceyTaskRow> {
  bool _executing = false;

  bool get _isRunning => widget.task.status == 'running' || _executing;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final statusColor = _getStatusColor(task.status);
    final successes = widget.logs.where((l) => l.status == 'success').length;
    final fails = widget.logs.where((l) => l.status == 'failed' || l.status == 'timeout').length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Status indicator + Type + ID
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: kBorder.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  task.type == 'recurring' ? 'RECURRING' : 'ONE-OFF',
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
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
          _buildTimingInfo(task),
          const SizedBox(height: 6),

          // Row 4: Stats + Action buttons
          Row(
            children: [
              Expanded(
                child: Text(
                  'Runs: ${task.totalRuns} • Success: $successes • Fails: $fails',
                  style: const TextStyle(color: kMuted, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),

              // Cancel button if running
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
                  onPressed: () => _cancelExecution(task.id),
                  icon: const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: kDanger),
                  ),
                  label: const Text('Cancel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ] else ...[
                _ActionButton(
                  icon: Icons.play_arrow_rounded,
                  tooltip: 'Run Now (test trigger)',
                  color: Colors.greenAccent,
                  onTap: () => _runNow(context, task.id),
                ),
                const SizedBox(width: 3),
                _ActionButton(
                  icon: task.status == 'paused'
                      ? Icons.play_circle_outline_rounded
                      : Icons.pause_circle_outline_rounded,
                  tooltip: task.status == 'paused' ? 'Resume Task' : 'Pause Task',
                  color: kMuted,
                  onTap: () => _togglePause(task),
                ),
              ],
              const SizedBox(width: 3),
              _ActionButton(
                icon: Icons.receipt_long_rounded,
                tooltip: 'View Logs & Output',
                color: kMuted,
                onTap: widget.onViewLogs,
              ),
              const SizedBox(width: 3),
              _ActionButton(
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

  Widget _buildTimingInfo(SchedulerTaskRow task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRun = task.nextRunAt ?? task.startsAt;
    final diff = nextRun - now;

    String timingText;
    if (task.status == 'running') {
      timingText = 'Executing now...';
    } else if (task.status == 'completed') {
      timingText = 'Run completed';
    } else if (task.status == 'paused') {
      timingText = 'Paused (no alarms active)';
    } else if (task.status == 'cancelled') {
      timingText = 'Cancelled';
    } else if (diff > 0) {
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
      timingText += ' • Repeats every ${intervalMin}m';
    }

    return Row(
      children: [
        Icon(Icons.schedule_rounded, color: kMuted.withValues(alpha: 0.8), size: 13),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            timingText,
            style: const TextStyle(color: kMuted, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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

  Future<void> _cancelExecution(int taskId) async {
    await TaskSchedulerService.instance.cancelRunningTask(taskId);
    if (mounted) {
      setState(() => _executing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Task #$taskId cancelled'),
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
    await TaskSchedulerService.instance.cancelTask(taskId);
    final db = widget.db;
    await (db.delete(db.schedulerTasks)..where((t) => t.id.equals(taskId))).go();
  }
}

// ---------------------------------------------------------------------------
// Compact Action Icon Button (Prevents overflows)
// ---------------------------------------------------------------------------

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({
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

// ---------------------------------------------------------------------------
// Spacey Unread / Log Item Widget
// ---------------------------------------------------------------------------

class _SpaceyLogItem extends StatelessWidget {
  final SchedulerTaskLogRow log;
  final SchedulerTaskRow? task;
  final VoidCallback onMarkSeen;

  const _SpaceyLogItem({
    required this.log,
    required this.task,
    required this.onMarkSeen,
  });

  @override
  Widget build(BuildContext context) {
    final isSuccess = log.status == 'success';
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
            // Top: status icon + status + timestamp + unread dot
            Row(
              children: [
                Icon(
                  isSuccess
                      ? Icons.check_circle_rounded
                      : (log.status == 'running'
                          ? Icons.sync_rounded
                          : Icons.error_outline_rounded),
                  color: isSuccess
                      ? Colors.greenAccent
                      : (log.status == 'running' ? Colors.amberAccent : kDanger),
                  size: 15,
                ),
                const SizedBox(width: 6),
                Text(
                  log.status.toUpperCase(),
                  style: TextStyle(
                    color: isSuccess
                        ? Colors.greenAccent
                        : (log.status == 'running' ? Colors.amberAccent : kDanger),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatTime(log.startedAt ?? log.createdAt),
                    style: const TextStyle(color: kMuted, fontSize: 11),
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
                  _ActionButton(
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

// ---------------------------------------------------------------------------
// Task Logs Modal (Bottom sheet for task-specific logs)
// ---------------------------------------------------------------------------

class _TaskLogsModal extends StatelessWidget {
  final int taskId;
  final String taskTitle;
  final ErrandDatabase db;

  const _TaskLogsModal({
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

                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return _SpaceyLogItem(
                        log: log,
                        task: null,
                        onMarkSeen: () async {
                          final now = DateTime.now().millisecondsSinceEpoch;
                          await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(log.id))).write(
                            SchedulerTaskLogsCompanion(
                              notificationSeen: const Value(1),
                              updatedAt: Value(now),
                            ),
                          );
                        },
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
}
