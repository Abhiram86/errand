import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import '../services/database.dart';
import '../services/task_scheduler_service.dart';
import '../services/workspace.dart';
import '../theme/app_colors.dart';
import '../utils/app_profile.dart';
import '../widgets/tasks/tasks_widgets.dart';

/// Full-screen management page for scheduled tasks, logs, and autonomous background runs.
class ManageTasksScreen extends StatefulWidget {
  final ErrandDatabase? database;
  final int initialTabIndex;
  final String? initialLogFilter;

  const ManageTasksScreen({
    super.key,
    this.database,
    this.initialTabIndex = 0,
    this.initialLogFilter,
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
  late String _unreadScopeFilter;
  int _logLimit = 25; // 25, 50, 100, 0 (all)

  // Filters for All Tasks Tab
  String _allStatusFilter = 'all'; // 'all', 'active', 'paused', 'completed', 'failed', 'cancelled'
  String _allTypeFilter = 'all'; // 'all', 'recurring', 'one_off'
  int _taskLimit = 25; // 25, 50, 100, 0 (all)
  final TextEditingController _taskSearchController = TextEditingController();
  String _taskSearchQuery = '';
  Timer? _taskSearchDebounce;

  late Future<bool> _exactAlarmsFuture;
  late final Stream<List<SchedulerTaskRow>> _tasksStream;
  late final Stream<List<SchedulerTaskLogRow>> _logsStream;

  /// Session-scoped storage footer: dismissed with the cross, shown again on
  /// every fresh app start (state resets with the screen).
  bool _showStorageFooter = true;
  String? _storageSummary;

  bool _p10FirstRowLogged = false;
  late final int _p10ScreenId;

  @override
  void initState() {
    super.initState();
    _unreadScopeFilter = widget.initialLogFilter ?? 'unread';
    _p10ScreenId = identityHashCode(this);
    WidgetsBinding.instance.addObserver(this);
    _taskSearchController.addListener(_onTaskSearchChanged);
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

  void _onTaskSearchChanged() {
    _taskSearchDebounce?.cancel();
    _taskSearchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final q = _taskSearchController.text.trim().toLowerCase();
      if (q != _taskSearchQuery) {
        setState(() {
          _taskSearchQuery = q;
        });
      }
    });
  }

  Timer? _runningTasksPollTimer;

  void _syncRunningTasksPolling(List<SchedulerTaskRow> tasks) {
    final hasRunning = tasks.any((t) => t.status == 'running');
    if (hasRunning) {
      if (_runningTasksPollTimer == null || !_runningTasksPollTimer!.isActive) {
        _runningTasksPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          if (!mounted) return;
          try {
            _db.markTablesUpdated([_db.schedulerTasks, _db.schedulerTaskLogs]);
          } catch (_) {}
        });
      }
    } else {
      _runningTasksPollTimer?.cancel();
      _runningTasksPollTimer = null;
    }
  }

  @override
  void dispose() {
    _runningTasksPollTimer?.cancel();
    _taskSearchDebounce?.cancel();
    _taskSearchController.removeListener(_onTaskSearchChanged);
    _taskSearchController.dispose();
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
        _syncRunningTasksPolling(allTasks);

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

            final unreadLogs = allLogs
                .where((l) =>
                    l.notificationSeen == 0 &&
                    l.notificationSent == 1 &&
                    l.status != 'running')
                .toList();

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
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded, color: kText),
                    color: kInputBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: kBorder, width: 0.8),
                    ),
                    tooltip: 'More actions',
                    onSelected: (action) async {
                      if (action == 'pause_all') {
                        await _pauseAll(allTasks);
                      } else if (action == 'resume_all') {
                        await _resumeAll(allTasks);
                      }
                    },
                    itemBuilder: (context) {
                      final scheduledCount =
                          allTasks.where((t) => t.status == 'scheduled').length;
                      final pausedCount =
                          allTasks.where((t) => t.status == 'paused').length;
                      return [
                        PopupMenuItem(
                          value: 'pause_all',
                          enabled: scheduledCount > 0,
                          child: Row(
                            children: [
                              const Icon(Icons.pause_circle_outline_rounded,
                                  color: kMuted, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Pause all schedules ($scheduledCount)',
                                  style: TextStyle(
                                    color: scheduledCount > 0
                                        ? kText
                                        : kMuted.withValues(alpha: 0.5),
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'resume_all',
                          enabled: pausedCount > 0,
                          child: Row(
                            children: [
                              const Icon(Icons.play_circle_outline_rounded,
                                  color: kMuted, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Resume all schedules ($pausedCount)',
                                  style: TextStyle(
                                    color: pausedCount > 0
                                        ? kText
                                        : kMuted.withValues(alpha: 0.5),
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ];
                    },
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

  Future<void> _pauseAll(List<SchedulerTaskRow> allTasks) async {
    await TaskSchedulerService.instance.pauseAllTasks();
  }

  Future<void> _resumeAll(List<SchedulerTaskRow> allTasks) async {
    await TaskSchedulerService.instance.resumeAllTasks();
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
                    return SpaceyTaskRow(
                      task: task,
                      logs: logsByTask[task.id] ?? const [],
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
      if (_unreadScopeFilter == 'unread' &&
          (l.notificationSeen != 0 || l.notificationSent != 1 || l.status == 'running')) {
        return false;
      }
      if (_unreadScopeFilter == 'failed' && l.status != 'failed' && l.status != 'timeout') {
        return false;
      }
      if (_unreadScopeFilter == 'success' && l.status != 'success') {
        return false;
      }
      return true;
    }).toList();

    final unreadCount = allLogs
        .where((l) =>
            l.notificationSeen == 0 &&
            l.notificationSent == 1 &&
            l.status != 'running')
        .length;
    final failedCount = allLogs.where((l) => l.status == 'failed' || l.status == 'timeout').length;
    final successCount = allLogs.where((l) => l.status == 'success').length;
    final displayedLogs = _logLimit > 0 ? filtered.take(_logLimit).toList() : filtered;

    String emptyTitle = 'No task logs';
    String emptySubtitle = 'No execution logs recorded yet.';
    if (_unreadScopeFilter == 'unread') {
      emptyTitle = 'All caught up!';
      emptySubtitle = 'No unread execution logs. Switch filters to review past runs.';
    } else if (_unreadScopeFilter == 'failed') {
      emptyTitle = 'No failed runs';
      emptySubtitle = 'All recorded runs completed without errors.';
    } else if (_unreadScopeFilter == 'success') {
      emptyTitle = 'No successful runs';
      emptySubtitle = 'No successful task runs recorded yet.';
    }

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
            if (failedCount > 0)
              _buildChoiceChip(
                label: 'Failed ($failedCount)',
                selected: _unreadScopeFilter == 'failed',
                onSelected: () => setState(() {
                  _unreadScopeFilter = 'failed';
                  _logLimit = 25;
                }),
              ),
            _buildChoiceChip(
              label: 'Success ($successCount)',
              selected: _unreadScopeFilter == 'success',
              onSelected: () => setState(() {
                _unreadScopeFilter = 'success';
                _logLimit = 25;
              }),
            ),
          ],
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  icon: Icons.mark_email_read_rounded,
                  title: emptyTitle,
                  subtitle: emptySubtitle,
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
                    return SpaceyLogItem(
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
      if (_taskSearchQuery.isNotEmpty) {
        final matchesTitle = t.title.toLowerCase().contains(_taskSearchQuery);
        final matchesId = t.id.toString() == _taskSearchQuery;
        if (!matchesTitle && !matchesId) return false;
      }
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
        Container(
          margin: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          decoration: BoxDecoration(
            color: kInputBg.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(20),
          ),
          child: TextField(
            controller: _taskSearchController,
            style: const TextStyle(color: kText, fontSize: 13),
            cursorColor: kBubbleUser,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search tasks by title or ID...',
              hintStyle: TextStyle(color: kMuted.withValues(alpha: 0.65), fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded, color: kMuted.withValues(alpha: 0.65), size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 34),
              suffixIcon: _taskSearchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, color: kMuted, size: 16),
                      splashRadius: 14,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () {
                        _taskSearchController.clear();
                        setState(() => _taskSearchQuery = '');
                      },
                    )
                  : null,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
        ),
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
                  subtitle: _taskSearchQuery.isNotEmpty
                      ? 'No tasks match "$_taskSearchQuery".'
                      : (tasks.isEmpty
                          ? 'No tasks created yet. Ask Errand to schedule something or tap the clock icon.'
                          : 'No tasks match the active filters.'),
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
                    return SpaceyTaskRow(
                      task: task,
                      logs: logsByTask[task.id] ?? const [],
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(bottom: BorderSide(color: kBorder.withValues(alpha: 0.25), width: 0.5)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading,
            const SizedBox(width: 8),
            Container(width: 1, height: 14, color: kBorder.withValues(alpha: 0.25)),
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
            Container(width: 1, height: 14, color: kBorder.withValues(alpha: 0.25)),
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
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: selected ? kBubbleUser.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kText : kMuted.withValues(alpha: 0.8),
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
            color: kInputBg.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
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
      builder: (context) => TaskLogsModal(
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
      builder: (context) => EditTaskModelSheet(
        task: task,
        db: _db,
      ),
    );
  }
}
