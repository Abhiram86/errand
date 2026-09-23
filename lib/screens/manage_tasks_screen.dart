import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/llm_provider.dart';
import '../models/model_option.dart';
import '../services/app_settings.dart';
import '../services/database.dart';
import '../services/model_catalog.dart';
import '../services/task_scheduler_service.dart';
import '../services/workspace.dart';
import '../theme/app_colors.dart';
import '../utils/app_profile.dart';
import 'task_file_preview_screen.dart';

/// Full-screen management page for scheduled tasks, logs, and autonomous background runs.
class ManageTasksScreen extends StatefulWidget {
  final ErrandDatabase? database;
  final int initialTabIndex;

  const ManageTasksScreen({
    super.key,
    this.database,
    this.initialTabIndex = 0,
  });

  @override
  State<ManageTasksScreen> createState() => _ManageTasksScreenState();
}

class _ManageTasksScreenState extends State<ManageTasksScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;
  late final ErrandDatabase _db;

  // Filters for Upcoming Tab
  String _upcomingTypeFilter = 'all'; // 'all', 'one_off', 'recurring'
  int _upcomingLimit = 50;

  // Filters for Unread Tab
  String _unreadScopeFilter = 'unread'; // 'unread', 'all'
  int _logLimit = 25; // 25, 50, 100, 0 (all)

  // Filters for All Tasks Tab
  String _allStatusFilter = 'all'; // 'all', 'active', 'paused', 'completed', 'failed', 'cancelled'
  String _allTypeFilter = 'all'; // 'all', 'recurring', 'one_off'
  int _taskLimit = 25; // 25, 50, 100, 0 (all)

  late Future<bool> _exactAlarmsFuture;
  late final Stream<List<SchedulerTaskRow>> _tasksStream;
  late final Stream<List<SchedulerTaskLogRow>> _logsStream;

  /// Session-scoped storage footer: dismissed with the cross, shown again on
  /// every fresh app start (state resets with the screen).
  bool _showStorageFooter = true;
  String? _storageSummary;

  bool _p10FirstRowLogged = false;
  late final int _p10ScreenId;

  /// 1s ticker so countdown labels ("Fires in Xs") stay live between stream events.
  Timer? _countdownTimer;

  /// Memoized per-task model overrides: task id -> (updatedAt, model).
  /// Avoids jsonDecode per row on every rebuild.
  final Map<int, ({int updatedAt, String? model})> _modelOverrideCache = {};

  @override
  void initState() {
    super.initState();
    _p10ScreenId = identityHashCode(this);
    WidgetsBinding.instance.addObserver(this);
    _db = widget.database ?? ErrandDatabase.instance;
    _tasksStream = (_db.select(_db.schedulerTasks)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
    _logsStream = (_db.select(_db.schedulerTaskLogs)
          ..orderBy([(l) => OrderingTerm.desc(l.createdAt)]))
        .watch();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: (widget.initialTabIndex >= 0 && widget.initialTabIndex < 3)
          ? widget.initialTabIndex
          : 0,
    );
    _exactAlarmsFuture = TaskSchedulerService.instance.canScheduleExactAlarms();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_loadStorageSummary());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => AppProfile.mark(
        'manage_tasks_first_frame screen=$_p10ScreenId tab=${widget.initialTabIndex}',
      ),
    );
  }

  /// Sums scratch report files once per screen open. Best-effort and silent.
  Future<void> _loadStorageSummary() async {
    try {
      final scratch = Workspace.instance.scratchDir;
      if (!scratch.existsSync()) return;
      var bytes = 0;
      var count = 0;
      for (final entry in scratch.listSync()) {
        if (entry is File) {
          try {
            bytes += entry.lengthSync();
            count++;
          } catch (_) {}
        }
      }
      if (!mounted) return;
      setState(() {
        _storageSummary =
            'Scratch ${_formatBytes(bytes)} · $count ${count == 1 ? 'file' : 'files'}';
      });
    } catch (_) {}
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildStorageFooter() {
    final summary = _storageSummary;
    if (!_showStorageFooter || summary == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, color: kMuted, size: 13),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              summary,
              style: const TextStyle(color: kMuted, fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => setState(() => _showStorageFooter = false),
            borderRadius: BorderRadius.circular(12),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, color: kMuted, size: 14),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // Background-isolate task writes are invisible to this isolate's drift
      // watch() streams; force a re-emission so resumed screens can't show
      // stale statuses.
      try {
        _db.markTablesUpdated([_db.schedulerTasks, _db.schedulerTaskLogs]);
      } catch (_) {}
      setState(() {
        _exactAlarmsFuture = TaskSchedulerService.instance.canScheduleExactAlarms();
      });
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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

            if (!_p10FirstRowLogged &&
                (allTasks.isNotEmpty || allLogs.isNotEmpty)) {
              _p10FirstRowLogged = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => AppProfile.mark(
                  'first_useful_row screen=$_p10ScreenId '
                  'tasks=${allTasks.length} logs=${allLogs.length}',
                ),
              );
            }

            // Group logs by task once per emission (O(T+L)) instead of
            // filtering per row in itemBuilder (O(T*L)).
            final logsByTask = <int, List<SchedulerTaskLogRow>>{};
            for (final log in allLogs) {
              (logsByTask[log.schedulerTaskId] ??= []).add(log);
            }

            final upcomingTasks = allTasks.where((t) {
              if (t.status == 'running') return true;
              if (t.status != 'scheduled') return false;
              return true;
            }).toList()
              ..sort(_compareUpcomingTasks);

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
                actions: const [
                  SizedBox(width: 4),
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
                        _buildUpcomingTab(upcomingTasks, logsByTask),
                        _buildUnreadTab(allLogs, allTasks),
                        _buildAllTasksTab(allTasks, logsByTask),
                      ],
                    ),
                  ),
                  _buildStorageFooter(),
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

  int _compareUpcomingTasks(SchedulerTaskRow a, SchedulerTaskRow b) {
    // A running task is active now, so keep it ahead of future scheduled work.
    if (a.status != b.status) {
      if (a.status == 'running') return -1;
      if (b.status == 'running') return 1;
    }

    final aNext = a.nextRunAt ?? a.startsAt;
    final bNext = b.nextRunAt ?? b.startsAt;
    final byNextRun = aNext.compareTo(bNext);
    if (byNextRun != 0) return byNextRun;

    // Stable tie-breakers keep rows from jumping when timestamps collide.
    final byCreated = b.createdAt.compareTo(a.createdAt);
    return byCreated != 0 ? byCreated : b.id.compareTo(a.id);
  }

  /// Returns the cached model override for [task], decoding payloadJson
  /// at most once per task update.
  String? _modelFor(SchedulerTaskRow task) {
    final cached = _modelOverrideCache[task.id];
    if (cached != null && cached.updatedAt == task.updatedAt) {
      return cached.model;
    }
    String? model;
    try {
      final payload = jsonDecode(task.payloadJson) as Map<String, dynamic>;
      final m = (payload['model'] as String?)?.trim();
      if (m != null && m.isNotEmpty) model = m;
    } catch (_) {}
    _modelOverrideCache[task.id] = (updatedAt: task.updatedAt, model: model);
    // Bound cache growth: drop entries for tasks no longer present.
    if (_modelOverrideCache.length > 500) _modelOverrideCache.clear();
    return model;
  }

  Widget _buildUpcomingTab(
    List<SchedulerTaskRow> tasks,
    Map<int, List<SchedulerTaskLogRow>> logsByTask,
  ) {
    final filtered = tasks.where((t) {
      if (_upcomingTypeFilter != 'all' && t.type != _upcomingTypeFilter) {
        return false;
      }
      return true;
    }).toList();
    final displayed = filtered.take(_upcomingLimit).toList();

    return Column(
      children: [
        _buildFilterBar(
          leading: _buildLimitSelector(
            currentLimit: _upcomingLimit,
            onChanged: (val) => setState(() => _upcomingLimit = val),
          ),
          children: [
            _buildChoiceChip(
              label: 'All (${tasks.length})',
              selected: _upcomingTypeFilter == 'all',
              onSelected: () => setState(() {
                _upcomingTypeFilter = 'all';
                _upcomingLimit = 50;
              }),
            ),
            _buildChoiceChip(
              label: 'Recurring',
              selected: _upcomingTypeFilter == 'recurring',
              onSelected: () => setState(() {
                _upcomingTypeFilter = 'recurring';
                _upcomingLimit = 50;
              }),
            ),
            _buildChoiceChip(
              label: 'One-off',
              selected: _upcomingTypeFilter == 'one_off',
              onSelected: () => setState(() {
                _upcomingTypeFilter = 'one_off';
                _upcomingLimit = 50;
              }),
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
                  itemCount: displayed.length + (filtered.length > displayed.length ? 1 : 0),
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    if (index == displayed.length) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _upcomingLimit += 50),
                            icon: const Icon(Icons.expand_more_rounded, size: 16),
                            label: Text('Load more (showing ${displayed.length} of ${filtered.length})'),
                            style: TextButton.styleFrom(
                              foregroundColor: kBubbleUser,
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      );
                    }
                    final task = displayed[index];
                    return _SpaceyTaskRow(
                      task: task,
                      logs: logsByTask[task.id] ?? const [],
                      modelOverride: _modelFor(task),
                      db: _db,
                      onViewLogs: () => _openTaskLogs(task),
                      onEditModel: () => _openEditModelModal(task),
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
    final displayedLogs = _logLimit > 0 ? filtered.take(_logLimit).toList() : filtered;

    return Column(
      children: [
        _buildFilterBar(
          leading: _buildLimitSelector(
            currentLimit: _logLimit,
            onChanged: (val) => setState(() => _logLimit = val),
          ),
          trailing: unreadCount > 0
              ? IconButton(
                  onPressed: _markAllLogsAsRead,
                  tooltip: 'Mark all as read',
                  icon: const Icon(Icons.done_all_rounded, size: 18, color: kBubbleUser),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                )
              : null,
          children: [
            _buildChoiceChip(
              label: 'Unread ($unreadCount)',
              selected: _unreadScopeFilter == 'unread',
              onSelected: () => setState(() {
                _unreadScopeFilter = 'unread';
                _logLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'All logs (${allLogs.length})',
              selected: _unreadScopeFilter == 'all',
              onSelected: () => setState(() {
                _unreadScopeFilter = 'all';
                _logLimit = 25;
              }),
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
                  itemCount: displayedLogs.length + (filtered.length > displayedLogs.length ? 1 : 0),
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    if (index == displayedLogs.length) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _logLimit += 25),
                            icon: const Icon(Icons.expand_more_rounded, size: 16),
                            label: Text('Load more (showing ${displayedLogs.length} of ${filtered.length})'),
                            style: TextButton.styleFrom(
                              foregroundColor: kBubbleUser,
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      );
                    }
                    final log = displayedLogs[index];
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

  Widget _buildAllTasksTab(
    List<SchedulerTaskRow> tasks,
    Map<int, List<SchedulerTaskLogRow>> logsByTask,
  ) {
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

    final displayedTasks = _taskLimit > 0 ? filtered.take(_taskLimit).toList() : filtered;

    return Column(
      children: [
        _buildFilterBar(
          leading: _buildLimitSelector(
            currentLimit: _taskLimit,
            onChanged: (val) => setState(() => _taskLimit = val),
          ),
          children: [
            _buildChoiceChip(
              label: 'All (${tasks.length})',
              selected: _allStatusFilter == 'all' && _allTypeFilter == 'all',
              onSelected: () => setState(() {
                _allStatusFilter = 'all';
                _allTypeFilter = 'all';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'Active',
              selected: _allStatusFilter == 'active',
              onSelected: () => setState(() {
                _allStatusFilter = _allStatusFilter == 'active' ? 'all' : 'active';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'Paused',
              selected: _allStatusFilter == 'paused',
              onSelected: () => setState(() {
                _allStatusFilter = _allStatusFilter == 'paused' ? 'all' : 'paused';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'Completed',
              selected: _allStatusFilter == 'completed',
              onSelected: () => setState(() {
                _allStatusFilter = _allStatusFilter == 'completed' ? 'all' : 'completed';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'Failed',
              selected: _allStatusFilter == 'failed',
              onSelected: () => setState(() {
                _allStatusFilter = _allStatusFilter == 'failed' ? 'all' : 'failed';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'Recurring',
              selected: _allTypeFilter == 'recurring',
              onSelected: () => setState(() {
                _allTypeFilter = _allTypeFilter == 'recurring' ? 'all' : 'recurring';
                _taskLimit = 25;
              }),
            ),
            _buildChoiceChip(
              label: 'One-off',
              selected: _allTypeFilter == 'one_off',
              onSelected: () => setState(() {
                _allTypeFilter = _allTypeFilter == 'one_off' ? 'all' : 'one_off';
                _taskLimit = 25;
              }),
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
                  itemCount: displayedTasks.length + (filtered.length > displayedTasks.length ? 1 : 0),
                  separatorBuilder: (_, _) => Divider(color: kBorder.withValues(alpha: 0.35), height: 1),
                  itemBuilder: (context, index) {
                    if (index == displayedTasks.length) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _taskLimit += 25),
                            icon: const Icon(Icons.expand_more_rounded, size: 16),
                            label: Text('Load more (showing ${displayedTasks.length} of ${filtered.length})'),
                            style: TextButton.styleFrom(
                              foregroundColor: kBubbleUser,
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      );
                    }
                    final task = displayedTasks[index];
                    return _SpaceyTaskRow(
                      task: task,
                      logs: logsByTask[task.id] ?? const [],
                      modelOverride: _modelFor(task),
                      db: _db,
                      onViewLogs: () => _openTaskLogs(task),
                      onEditModel: () => _openEditModelModal(task),
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

  Widget _buildFilterBar({
    required List<Widget> children,
    Widget? leading,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: kInputBg.withValues(alpha: 0.4),
        border: const Border(bottom: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading,
            const SizedBox(width: 8),
            Container(width: 1, height: 18, color: kBorder.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Container(width: 1, height: 18, color: kBorder.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            trailing,
          ],
        ],
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

  Widget _buildLimitSelector({
    required int currentLimit,
    required ValueChanged<int> onChanged,
  }) {
    final label = currentLimit == 0 ? 'Limit: All' : 'Limit: $currentLimit';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: PopupMenuButton<int>(
        initialValue: currentLimit,
        onSelected: onChanged,
        tooltip: 'Change display limit',
        color: kInputBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: kBorder, width: 0.8),
        ),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 25, child: Text('Show 25', style: TextStyle(color: kText, fontSize: 13))),
          PopupMenuItem(value: 50, child: Text('Show 50', style: TextStyle(color: kText, fontSize: 13))),
          PopupMenuItem(value: 100, child: Text('Show 100', style: TextStyle(color: kText, fontSize: 13))),
          PopupMenuItem(value: 0, child: Text('Show All', style: TextStyle(color: kText, fontSize: 13))),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder.withValues(alpha: 0.6), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(color: kMuted, fontSize: 11),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.arrow_drop_down_rounded, size: 14, color: kMuted),
            ],
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

  void _openEditModelModal(SchedulerTaskRow task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kInputBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _EditTaskModelSheet(
        task: task,
        db: _db,
        onSaved: (newModel) {
          setState(() {
            _modelOverrideCache[task.id] = (
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              model: newModel,
            );
          });
        },
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
  final String? modelOverride;
  final ErrandDatabase db;
  final VoidCallback onViewLogs;
  final VoidCallback? onEditModel;

  const _SpaceyTaskRow({
    required this.task,
    required this.logs,
    this.modelOverride,
    required this.db,
    required this.onViewLogs,
    this.onEditModel,
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

    // Model override resolved + memoized by the parent list (see _modelFor).
    final overriddenModel = widget.modelOverride;

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
              if (overriddenModel != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: widget.onEditModel,
                  borderRadius: BorderRadius.circular(5),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 110),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: kBubbleUser.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: kBubbleUser.withValues(alpha: 0.35), width: 0.6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.psychology_rounded, size: 10, color: kBubbleUser),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            overriddenModel,
                            style: const TextStyle(
                              color: kBubbleUser,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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
                  'Runs: ${task.totalRuns}',
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
              if (widget.onEditModel != null) ...[
                const SizedBox(width: 3),
                _ActionButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'Edit Model & Provider',
                  color: kMuted,
                  onTap: widget.onEditModel,
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
    final deleted = await TaskSchedulerService.instance.deleteTask(taskId);
    if (!deleted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task not found — already deleted')),
      );
    }
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

class _LogStatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _LogStatChip({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

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
                            _LogStatChip(
                              value: '${logs.length}',
                              label: 'runs',
                              color: kMuted,
                            ),
                            const SizedBox(width: 8),
                            _LogStatChip(
                              value: '$succeeded',
                              label: 'succeeded',
                              color: Colors.greenAccent,
                            ),
                            const SizedBox(width: 8),
                            _LogStatChip(
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
                            return _SpaceyLogItem(
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

// ---------------------------------------------------------------------------
// Bottom Sheet to Edit Provider & Model for a Task
// ---------------------------------------------------------------------------

class _EditTaskModelSheet extends StatefulWidget {
  final SchedulerTaskRow task;
  final ErrandDatabase db;
  final ValueChanged<String>? onSaved;

  const _EditTaskModelSheet({
    required this.task,
    required this.db,
    this.onSaved,
  });

  @override
  State<_EditTaskModelSheet> createState() => _EditTaskModelSheetState();
}

class _EditTaskModelSheetState extends State<_EditTaskModelSheet> {
  late final AppSettingsService _settings;
  String? _selectedProviderId;
  String _selectedModel = '';
  List<ModelOption> _models = [];
  bool _loadingModels = false;
  bool _customModelMode = false;
  late final TextEditingController _customModelController;
  bool _saving = false;
  // Set once the user picks anything; guards the settings-ready refresh
  // below from clobbering an in-progress choice.
  bool _userTouchedSelection = false;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsService.instance;

    _resolveInitialSelection();
    _customModelController = TextEditingController(text: _selectedModel);
    _customModelController.addListener(_markSelectionTouched);

    _loadModelsForProvider(_selectedProviderId);

    // Cold-tap path can open this sheet before settings finish loading,
    // leaving provider/model resolved from empty defaults. Re-resolve once
    // settings are ready unless the user already chose something.
    unawaited(AppSettingsService.instance.ensureLoaded().then((_) {
      if (!mounted || _userTouchedSelection) return;
      final prevProvider = _selectedProviderId;
      final prevModel = _selectedModel;
      _resolveInitialSelection();
      if (_selectedProviderId == prevProvider &&
          _selectedModel == prevModel) {
        return;
      }
      _customModelController.text = _selectedModel;
      if (!mounted) return;
      setState(() {});
      if (_selectedProviderId != prevProvider) {
        _loadModelsForProvider(_selectedProviderId);
      }
    }).catchError((_) {}));
  }

  void _markSelectionTouched() {
    _userTouchedSelection = true;
  }

  /// Resolves provider/model from task payload with global fallbacks.
  /// No setState: callers handle notifying (initState runs pre-build).
  void _resolveInitialSelection() {
    String initialModel = '';
    String? initialProvider;
    try {
      final payload = jsonDecode(widget.task.payloadJson) as Map<String, dynamic>;
      initialModel = (payload['model'] as String?)?.trim() ?? '';
      initialProvider = (payload['providerId'] as String?)?.trim();
    } catch (_) {}

    if (initialModel.isEmpty) {
      initialModel = _settings.selectedModel;
    }
    _selectedModel = initialModel;
    // Normalize the provider up front so display and save always agree:
    // fall back to the active (or first) provider when the stored id is gone.
    var resolvedProvider = initialProvider ?? _settings.activeProviderId;
    final knownIds = _settings.providers.map((p) => p.id).toSet();
    if (!knownIds.contains(resolvedProvider)) {
      resolvedProvider = knownIds.contains(_settings.activeProviderId)
          ? _settings.activeProviderId
          : (_settings.providers.isNotEmpty
              ? _settings.providers.first.id
              : _settings.activeProviderId);
    }
    _selectedProviderId = resolvedProvider;
  }

  @override
  void dispose() {
    _customModelController.dispose();
    super.dispose();
  }

  Future<void> _loadModelsForProvider(String? providerId,
      {bool resetModelIfMissing = false}) async {
    if (providerId == null) return;
    final provider = _settings.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => _settings.activeProvider,
    );

    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final fallbackList = List<ModelOption>.from(
      (cached != null && cached.isNotEmpty) ? cached : provider.defaultModels,
    )..sort(ModelOption.compareByReleaseDate);

    setState(() {
      _models = fallbackList;
      _loadingModels = cached == null;
      // Switching provider orphaned the selected model: follow the provider
      // instead of persisting a model that doesn't belong to it.
      if (resetModelIfMissing &&
          _selectedModel.isNotEmpty &&
          !fallbackList.any((m) => m.id == _selectedModel) &&
          fallbackList.isNotEmpty) {
        _selectedModel = fallbackList.first.id;
      }
    });

    final hasKey = provider.hasKey ||
        (provider.id == ProviderPresetType.openRouter.id && _settings.hasOpenRouterKey);

    if (cached == null && hasKey) {
      final apiKey = provider.id == ProviderPresetType.openRouter.id
          ? (provider.apiKey ?? _settings.openRouterKey ?? '')
          : (provider.apiKey ?? '');
      try {
        final fetched = await ModelCatalogService().load(
          baseUrl: provider.baseUrl.isNotEmpty ? provider.baseUrl : provider.defaultBaseUrl,
          apiKey: apiKey,
          defaultProvider: provider.name,
          isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
              provider.baseUrl.contains('openrouter.ai'),
        );
        if (mounted && _selectedProviderId == providerId) {
          final sorted = List<ModelOption>.from(fetched)..sort(ModelOption.compareByReleaseDate);
          setState(() {
            _models = sorted;
            _loadingModels = false;
            if (resetModelIfMissing &&
                _selectedModel.isNotEmpty &&
                !sorted.any((m) => m.id == _selectedModel) &&
                sorted.isNotEmpty) {
              _selectedModel = sorted.first.id;
            }
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loadingModels = false);
      }
    } else {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _save() async {
    final finalModel = _customModelMode
        ? _customModelController.text.trim()
        : _selectedModel.trim();
    if (finalModel.isEmpty || _saving) return;

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Fetch the freshest row from DB to avoid any stale data overwrites
    final freshTask = await (widget.db.select(widget.db.schedulerTasks)
          ..where((t) => t.id.equals(widget.task.id)))
        .getSingleOrNull();
    if (freshTask == null) return;

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(freshTask.payloadJson) as Map<String, dynamic>;
    } catch (_) {}

    payload['model'] = finalModel;
    if (_selectedProviderId != null && _selectedProviderId!.isNotEmpty) {
      payload['providerId'] = _selectedProviderId;
    }

    try {
      final newPayloadJson = jsonEncode(payload);

      await (widget.db.update(widget.db.schedulerTasks)..where((t) => t.id.equals(widget.task.id))).write(
        SchedulerTasksCompanion(
          payloadJson: Value(newPayloadJson),
          updatedAt: Value(now),
        ),
      );

      widget.onSaved?.call(finalModel);

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Updated execution model for Task #${widget.task.id}'),
          backgroundColor: kBubbleUser,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save model override: $e'),
          backgroundColor: kDanger,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = _settings.providers;
    final activeProviderId = providers.any((p) => p.id == _selectedProviderId)
        ? _selectedProviderId
        : (providers.isNotEmpty ? providers.first.id : null);

    final modelInList = _models.any((m) => m.id == _selectedModel);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_rounded, color: kBubbleUser, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Task Model Override (#${widget.task.id})',
                  style: const TextStyle(
                    color: kText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: kMuted, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.task.title,
            style: const TextStyle(color: kMuted, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),

          // Provider selector
          const Text(
            'LLM Provider',
            style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kDarkBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder, width: 0.8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: activeProviderId,
                dropdownColor: kInputBg,
                icon: const Icon(Icons.arrow_drop_down_rounded, color: kMuted),
                isExpanded: true,
                items: providers.map((p) {
                  return DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(
                      p.name,
                      style: const TextStyle(color: kText, fontSize: 13),
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedProviderId = val;
                      _customModelMode = false;
                      _userTouchedSelection = true;
                    });
                    _loadModelsForProvider(val, resetModelIfMissing: true);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Model selector / text field header
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Model',
                  style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
              if (_loadingModels) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: kBubbleUser),
                ),
                const SizedBox(width: 8),
              ],
              InkWell(
                onTap: () {
                  setState(() {
                    _customModelMode = !_customModelMode;
                    _userTouchedSelection = true;
                    if (_customModelMode) {
                      _customModelController.text = _selectedModel;
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    _customModelMode ? 'Pick from list' : 'Custom / ID',
                    style: const TextStyle(
                      color: kBubbleUser,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          if (_customModelMode) ...[
            TextField(
              controller: _customModelController,
              style: const TextStyle(color: kText, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g. google/gemini-2.5-flash',
                hintStyle: TextStyle(color: kMuted.withValues(alpha: 0.5), fontSize: 13),
                filled: true,
                fillColor: kDarkBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kBorder, width: 0.8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kBorder, width: 0.8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kBubbleUser, width: 1.2),
                ),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: kDarkBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kBorder, width: 0.8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  // Display always equals the stored value: the extra item
                  // below guarantees membership, so what you see is what saves.
                  value: _selectedModel.isNotEmpty ? _selectedModel : null,
                  hint: const Text(
                    'Select model',
                    style: TextStyle(color: kMuted, fontSize: 13),
                  ),
                  dropdownColor: kInputBg,
                  icon: const Icon(Icons.arrow_drop_down_rounded, color: kMuted),
                  isExpanded: true,
                  menuMaxHeight: 320,
                  items: [
                    if (!modelInList && _selectedModel.isNotEmpty)
                      DropdownMenuItem<String>(
                        value: _selectedModel,
                        child: Text(
                          _selectedModel,
                          style: const TextStyle(color: kText, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ..._models.map((m) {
                      return DropdownMenuItem<String>(
                        value: m.id,
                        child: Text(
                          m.name.isNotEmpty && m.name != m.id ? '${m.name} (${m.id})' : m.id,
                          style: const TextStyle(color: kText, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _selectedModel = val;
                        _userTouchedSelection = true;
                      });
                    }
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),

          // Save button (blocked while models load so a stale
          // selection can never be persisted for the new provider)
          ElevatedButton(
            onPressed: (_saving || _loadingModels) ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: kBubbleUser,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text(
                    'Save Changes',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
          ),
        ],
      ),
    );
  }
}
