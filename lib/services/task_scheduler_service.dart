import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_loop.dart';
import '../agent/agent_runner.dart';
import '../agent/task_checkpoint.dart';
import '../llm/llm_client.dart';
import '../models/llm_provider.dart';
import '../services/app_settings.dart';
import '../services/database.dart';
import '../services/grant_flow_service.dart';
import '../services/notification_service.dart';
import '../services/task_progress_service.dart';
import '../services/workspace.dart';
import '../tools/file_tools.dart';
import '../utils/app_profile.dart';

/// Service responsible for coordinating background task scheduling with
/// native Android AlarmManager and WorkManager.
/// Result of [TaskSchedulerService.computeEditTransition]: the status,
// next run time, and stored interval a settings edit should persist.
class TaskEditTransition {
  final String status;
  final int? nextRunAt;
  final int? repeatAfter;

  const TaskEditTransition({
    required this.status,
    required this.nextRunAt,
    required this.repeatAfter,
  });
}

class TaskSchedulerService {
  static final TaskSchedulerService instance = TaskSchedulerService();

  final ErrandDatabase db;
  final NotificationService notificationService;

  TaskSchedulerService({
    ErrandDatabase? database,
    NotificationService? notificationService,
  })  : db = database ?? ErrandDatabase.instance,
        notificationService =
            notificationService ?? NotificationService.instance;

  static const MethodChannel _channel = MethodChannel('task_scheduler');

  static const String _kInexactFallbackKey = 'pref.scheduler_inexact_fallback';

  /// Sticky record that a schedule fell back to inexact timing.
  ///
  /// `scheduleAlarm` returning false was previously only a debugPrint —
  /// invisible in release builds. The Manage Tasks banner already reflects the
  /// permission state, but it cannot see a fallback that happened while
  /// permission *appears* granted (transient denial) or before the screen ever
  /// checked. Set on an explicit `false`, cleared on an explicit `true` or
  /// when the screen observes permission granted. Persisted so it survives
  /// restarts; the banner listens to this notifier.
  final ValueNotifier<bool> inexactFallbackActive = ValueNotifier(false);

  final Map<int, CancelToken> _runningTokens = {};
  /// Checks if a task is currently executing in-process.
  bool isTaskRunning(int taskId) => _runningTokens.containsKey(taskId);

  /// Normalizes an absolute or relative file path to a scratch-relative path.
  static String toScratchRelative(String pathStr, [Directory? scratchDir]) {
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    final scratchPath = scratch.path;
    if (p.isWithin(scratchPath, pathStr)) {
      return p.relative(pathStr, from: scratchPath);
    }
    if (!p.isAbsolute(pathStr)) {
      return pathStr;
    }
    final parts = p.split(pathStr);
    final scratchIdx = parts.lastIndexOf('scratch');
    if (scratchIdx != -1 && scratchIdx < parts.length - 1) {
      return p.joinAll(parts.sublist(scratchIdx + 1));
    }
    return p.basename(pathStr);
  }

  /// Resolves a stored path (scratch-relative or legacy absolute) into an
  /// absolute path within the current [scratchDir].
  /// Resolves a stored path (scratch-relative, workspace-relative, file:// URI,
  /// or legacy absolute) into an absolute path on disk.
  static String resolveReportPath(
    String? pathStr, [
    Directory? scratchDir,
    Directory? workspaceDir,
  ]) {
    if (pathStr == null || pathStr.trim().isEmpty) return '';
    var clean = pathStr.trim();
    if (clean.startsWith('file://')) {
      final uri = Uri.tryParse(clean);
      if (uri != null && uri.path.isNotEmpty) {
        clean = uri.toFilePath();
      } else {
        clean = clean.replaceFirst(RegExp(r'^file://+'), '/');
      }
    }
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    final workspace = workspaceDir ?? Workspace.instance.documentsDir;

    if (p.isAbsolute(clean)) {
      if (File(clean).existsSync()) {
        return clean;
      }
      final rel = toScratchRelative(clean, scratch);
      final inScratch = p.join(scratch.path, rel);
      if (File(inScratch).existsSync()) return inScratch;
      final inWs = p.join(workspace.path, rel);
      if (File(inWs).existsSync()) return inWs;
      return inScratch;
    }

    final inScratch = p.join(scratch.path, clean);
    if (File(inScratch).existsSync()) return inScratch;

    final inWs = p.join(workspace.path, clean);
    if (File(inWs).existsSync()) return inWs;

    return inScratch;
  }

  /// Probes network connectivity before starting an autonomous background turn.
  /// Gives the cellular radio up to [timeout] to transition from dormant RRC_IDLE
  /// to an active connected state.
  ///
  /// DNS alone is not enough: captive portals, firewall blocks, and half-up
  /// radios all resolve fine and fail later at TCP/TLS, burning the run's
  /// retry budget anyway. So a successful lookup is followed by a TCP connect
  /// to [port] (443: every LLM baseUrl is HTTPS except bypassed local hosts).
  static Future<bool> probeNetworkReadiness({
    String host = 'openrouter.ai',
    int port = 443,
    Duration timeout = const Duration(seconds: 15),
    Future<List<InternetAddress>> Function(String host)? lookupFn,
    Future<Socket> Function(String host, int port)? connectFn,
  }) async {
    final cleanHost = host.trim();
    if (cleanHost.isEmpty ||
        cleanHost == 'localhost' ||
        cleanHost == '127.0.0.1') {
      return true;
    }
    if (InternetAddress.tryParse(cleanHost) != null) {
      return true;
    }
    final deadline = DateTime.now().add(timeout);
    final lookup = lookupFn ?? InternetAddress.lookup;
    final connect = connectFn ??
        (h, p) => Socket.connect(h, p, timeout: const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final addresses = await lookup(cleanHost).timeout(
          const Duration(seconds: 3),
        );
        if (addresses.isNotEmpty) {
          // DNS resolves but the path may still be dead: prove TCP works.
          final socket = await connect(cleanHost, port).timeout(
            const Duration(seconds: 3),
          );
          socket.destroy();
          return true;
        }
      } catch (_) {
        // Cellular radio still negotiating, DNS unresolved, or TCP refused.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  /// Containment guard for destructive paths: true only when [absPath]
  /// normalizes to a location inside [scratchDir]. Delete/prune/owned-file
  /// enumeration must refuse anything else — stored rows can hold legacy
  /// absolute paths outside scratch (or `..` segments), and deleting those
  /// would destroy user files the task never owned.
  static bool isScratchOwned(String absPath, [Directory? scratchDir]) {
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    try {
      return p.isWithin(
        p.normalize(scratch.path),
        p.normalize(absPath),
      );
    } catch (_) {
      return false;
    }
  }

  /// Containment guard for task-owned paths: true only when [absPath]
  /// normalizes to a location inside [scratchDir] OR [workspaceDir].
  /// Refuses anything outside these sandboxes so deleting task files
  /// cannot touch arbitrary system or user directories.
  static bool isTaskOwnedPath(
    String absPath, {
    Directory? scratchDir,
    Directory? workspaceDir,
  }) {
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    final workspace = workspaceDir ?? Workspace.instance.documentsDir;
    try {
      final normalized = p.normalize(absPath);
      final scratchPath = p.normalize(scratch.path);
      if (p.isWithin(scratchPath, normalized) || p.equals(scratchPath, normalized)) {
        return true;
      }
      final wsPath = p.normalize(workspace.path);
      if (p.isWithin(wsPath, normalized) || p.equals(wsPath, normalized)) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Parses the JSON array in [linkedFilesRaw] into a list of strings.
  static List<String> parseLinkedFiles(String? linkedFilesRaw) {
    if (linkedFilesRaw == null || linkedFilesRaw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(linkedFilesRaw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Returns all existing [File]s on disk owned by [taskId] across all its logs
  /// (both primary report paths and linked files).
  Future<List<File>> getOwnedFilesForTask(
    int taskId, [
    Directory? scratchDir,
    Directory? workspaceDir,
  ]) async {
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    final workspace = workspaceDir ?? Workspace.instance.documentsDir;
    final logs = await (db.select(db.schedulerTaskLogs)
          ..where((l) => l.schedulerTaskId.equals(taskId)))
        .get();

    final files = <String, File>{};

    void addIfOwned(String absPath) {
      if (absPath.isEmpty) return;
      if (isTaskOwnedPath(absPath, scratchDir: scratch, workspaceDir: workspace)) {
        final file = File(absPath);
        if (file.existsSync()) {
          files[file.path] = file;
        }
      }
    }

    for (final log in logs) {
      if (log.outputFilePath != null && log.outputFilePath!.isNotEmpty) {
        final absPath = resolveReportPath(log.outputFilePath, scratch, workspace);
        addIfOwned(absPath);
      }
      for (final rel in parseLinkedFiles(log.linkedFiles)) {
        final absPath = resolveReportPath(rel, scratch, workspace);
        addIfOwned(absPath);

        // Also check if `rel` was a scratch link copy (e.g. task-1-123-link-foo.csv)
        // and check if original file exists in workspace. Guard against innocent
        // same-named files by verifying size and modification timestamp against task run.
        final base = p.basename(rel);
        final match = RegExp(r'^task-(\d+)-(\d+)-link-(.+)$').firstMatch(base);
        if (match != null) {
          final origName = match.group(3);
          final startedAt = int.tryParse(match.group(2) ?? '');
          if (origName != null && origName.isNotEmpty) {
            final wsFile = File(p.join(workspace.path, origName));
            if (wsFile.existsSync()) {
              final scratchCopy = File(absPath);
              var isMatch = true;
              if (scratchCopy.existsSync()) {
                if (wsFile.lengthSync() != scratchCopy.lengthSync()) {
                  isMatch = false;
                }
              }
              if (startedAt != null) {
                final lastMod = wsFile.lastModifiedSync().millisecondsSinceEpoch;
                // Files modified before task started were not created by this task
                if (lastMod < startedAt - 5000) {
                  isMatch = false;
                }
              }
              if (isMatch) {
                addIfOwned(wsFile.path);
              }
            }
          }
        }
      }
    }

    // Also scan scratch for any task-$taskId-* files (both reports and link
    // copies, recursively). The walk is offloaded: this runs on a user tap
    // (the delete dialog, clear-logs), and a recursive listSync on the UI
    // isolate stalls the frame for the whole tree.
    final scratchPath = scratch.path;
    final prefix = 'task-$taskId-';
    final matches = await Isolate.run(() {
      final found = <String>[];
      try {
        final dir = Directory(scratchPath);
        if (!dir.existsSync()) return found;
        for (final entity
            in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is File && p.basename(entity.path).startsWith(prefix)) {
            found.add(entity.path);
          }
        }
      } catch (_) {}
      return found;
    });
    for (final path in matches) {
      addIfOwned(path);
    }

    return files.values.toList();
  }

  /// Computes the count and total size in bytes of existing files owned by [taskId].
  Future<({int count, int bytes})> getTaskFileStats(
    int taskId, [
    Directory? scratchDir,
    Directory? workspaceDir,
  ]) async {
    final files = await getOwnedFilesForTask(taskId, scratchDir, workspaceDir);
    var bytes = 0;
    for (final f in files) {
      try {
        bytes += f.lengthSync();
      } catch (_) {}
    }
    return (count: files.length, bytes: bytes);
  }

  /// Scans [scratchDir] and finds all files not referenced by any execution
  /// log's [outputFilePath] or [linkedFiles].
  Future<List<File>> getOrphanedFiles([Directory? scratchDir]) async {
    final scratch = scratchDir ?? Workspace.instance.scratchDir;
    if (!scratch.existsSync()) return const [];

    // Only the two columns the sweep needs, with no LIMIT. A limit would
    // misclassify files referenced only by older log rows as orphans, and
    // the clear-orphans path deletes on tap without a per-file review.
    // The scan stays cheap as a two-column selectOnly; the directory walk
    // and the stat/unlink pass are the expensive parts and both run off
    // the UI isolate below.
    final logs = await (db.selectOnly(db.schedulerTaskLogs)
          ..addColumns([db.schedulerTaskLogs.outputFilePath, db.schedulerTaskLogs.linkedFiles]))
        .get();
    final referencedNames = <String>{};

    for (final row in logs) {
      final outputPath = row.read(db.schedulerTaskLogs.outputFilePath);
      if (outputPath != null && outputPath.isNotEmpty) {
        final rel = toScratchRelative(outputPath, scratch);
        referencedNames.add(rel);
        referencedNames.add(p.basename(rel));
      }
      for (final rel in parseLinkedFiles(row.read(db.schedulerTaskLogs.linkedFiles))) {
        final relPath = toScratchRelative(rel, scratch);
        referencedNames.add(relPath);
        referencedNames.add(p.basename(relPath));
      }
    }

    // The recursive directory walk is synchronous, unbounded disk IO on the UI
    // isolate — it runs on a user tap (storage summary, clear-orphans, the
    // delete dialog). Offload it; only paths cross the isolate boundary.
    final scratchPath = scratch.path;
    final candidates = await Isolate.run(() {
      final found = <String>[];
      try {
        final dir = Directory(scratchPath);
        if (!dir.existsSync()) return found;
        for (final entity in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is File) found.add(entity.path);
        }
      } catch (_) {}
      return found;
    });

    final orphans = <File>[];
    try {
      for (final path in candidates) {
        final rel = p.relative(path, from: scratch.path);
        final base = p.basename(path);
        // Ephemeral runtime state, not abandoned output: in-flight temp
        // files and task checkpoints/resume counters. Clearing one mid-run
        // would silently downgrade the next recovery to a fresh start.
        if (base.endsWith('-checkpoint.json') ||
            base.endsWith('-resumecount') ||
            base.endsWith('.tmp')) {
          continue;
        }
        if (!referencedNames.contains(rel) && !referencedNames.contains(base)) {
          orphans.add(File(path));
        }
      }
    } catch (_) {}
    return orphans;
  }

  /// Deletes all orphaned files in [scratchDir] and returns count and bytes cleared.
  Future<({int count, int bytes})> sweepOrphanFiles([Directory? scratchDir]) async {
    final orphans = await getOrphanedFiles(scratchDir);
    // stat + unlink per orphan is unbounded synchronous disk IO on the UI
    // isolate, reached from a "Clear orphaned files" tap. Offload it.
    final paths = orphans.map((f) => f.path).toList(growable: false);
    final result = await Isolate.run(() {
      var count = 0;
      var bytes = 0;
      for (final path in paths) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            final len = file.lengthSync();
            file.deleteSync();
            count++;
            bytes += len;
          }
        } catch (_) {}
      }
      return (count: count, bytes: bytes);
    });
    return result;
  }

  /// Deletes a task and everything tied to it: stops an in-flight run first
  /// so it cannot complete-or-notify afterwards, then cancels the native
  /// alarm and posted notification before removing the row (logs cascade).
  ///
  /// When [deleteFiles] is true, removes all report and linked output files
  /// stored on disk for this task. Returns false when the task does not exist.
  Future<bool> deleteTask(
    int taskId, {
    bool deleteFiles = false,
    Directory? scratchDir,
    Directory? workspaceDir,
  }) async {
    final existing = await (db.select(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (existing == null) return false;
    await cancelRunningTask(taskId);
    await cancelTask(taskId);
    try {
      await notificationService.cancelNotification(taskId);
    } catch (_) {}

    if (deleteFiles) {
      try {
        final files = await getOwnedFilesForTask(taskId, scratchDir, workspaceDir);
        for (final f in files) {
          try {
            if (f.existsSync()) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    await (db.delete(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .go();
    return true;
  }

  /// Clears all execution logs for [taskId].
  /// When [deleteFiles] is true, also deletes all report files and linked files
  /// associated with those logs.
  Future<int> deleteLogsForTask(
    int taskId, {
    bool deleteFiles = false,
    Directory? scratchDir,
    Directory? workspaceDir,
  }) async {
    if (deleteFiles) {
      try {
        final files = await getOwnedFilesForTask(taskId, scratchDir, workspaceDir);
        for (final f in files) {
          try {
            if (f.existsSync()) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return (db.delete(db.schedulerTaskLogs)
          ..where((l) => l.schedulerTaskId.equals(taskId)))
        .go();
  }

  /// Returns the number of execution logs that still have an unseen
  /// completion notification.
  /// Log statuses that represent a finished run and can therefore carry an
  /// unread completion notification.
  ///
  /// Single source of truth: `unreadNotificationCount` and the Manage Tasks
  /// badge previously used different predicates (`isIn([...])` here versus
  /// `status != 'running'` in the screen's raw SQL), so any status not in this
  /// list counted for the badge but not for the service. "Mark all as read"
  /// and the startup banner then disagreed with the tab count.
  static const List<String> terminalLogStatuses = [
    'success',
    'failed',
    'timeout',
    'cancelled',
  ];

  /// SQL fragment matching the same set as [terminalLogStatuses].
  ///
  /// Kept as a literal string list so the badge's raw SQL cannot drift from the
  /// Drift expression above. Kept in sync by the test that asserts this
  /// fragment contains exactly these statuses.
  static String get terminalLogStatusesSql {
    final quoted = terminalLogStatuses.map((s) => "'$s'").join(', ');
    return 'status IN ($quoted)';
  }

  /// Drift expression matching the same set as [terminalLogStatuses].
  ///
  /// Used by [unreadNotificationCount]; the Manage Tasks badge uses the raw-SQL
  /// form [terminalLogStatusesSql] via `customSelect` so the COUNT stays a
  /// single index-backed statement.
  Expression<bool> terminalLogStatusPredicate() =>
      db.schedulerTaskLogs.status.isIn(terminalLogStatuses);

  Future<int> unreadNotificationCount() async {
    final count = db.schedulerTaskLogs.id.count();
    final row = await (db.selectOnly(db.schedulerTaskLogs)
          ..addColumns([count])
          ..where(db.schedulerTaskLogs.notificationSeen.equals(0) &
              db.schedulerTaskLogs.notificationSent.equals(1) &
              terminalLogStatusPredicate()))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Marks unseen terminal logs for [taskId] as seen when its notification is tapped.
  /// Running rows are excluded: a tap that lands mid-run must not consume
  /// the completion's unread state.
  Future<void> markNotificationTapped(int taskId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (db.update(db.schedulerTaskLogs)
          ..where((l) =>
              l.schedulerTaskId.equals(taskId) &
              l.notificationSeen.equals(0) &
              l.status.isIn(const [
                'success',
                'failed',
                'timeout',
                'cancelled',
              ])))
        .write(
      SchedulerTaskLogsCompanion(
        notificationSeen: const Value(1),
        updatedAt: Value(now),
      ),
    );
  }

  /// Cancels an actively running task execution and marks it cancelled in the database.
  Future<void> cancelRunningTask(int taskId) async {
    final token = _runningTokens[taskId];
    token?.cancel();

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    await (db.update(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId) & t.status.equals('running')))
        .write(
      SchedulerTasksCompanion(
        status: const Value('cancelled'),
        nextRunAt: const Value(null),
        updatedAt: Value(nowMillis),
      ),
    );

    await (db.update(db.schedulerTaskLogs)
          ..where((l) =>
              l.schedulerTaskId.equals(taskId) & l.status.equals('running')))
        .write(
      SchedulerTaskLogsCompanion(
        status: const Value('cancelled'),
        finishedAt: Value(nowMillis),
        errorMessage: const Value('Cancelled by user'),
        updatedAt: Value(nowMillis),
      ),
    );
    try {
      await TaskCheckpoint.delete(taskId, Workspace.instance.scratchDir);
    } catch (_) {}
  }

  /// Skips the current run of a recurring task without killing the series:
  /// aborts in-flight work, recomputes the next grid slot, and re-arms the
  /// alarm. Non-recurring tasks fall back to [cancelRunningTask] (for a
  /// one-off, skipping the run and cancelling the task are the same thing).
  /// Returns false when the task does not exist.
  Future<bool> skipCurrentRun(int taskId) async {
    final task = await (db.select(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (task == null) return false;
    // Only live series can skip: terminal states have nothing in flight,
    // and a paused series must stay paused (no re-arm).
    if (task.status == 'completed' ||
        task.status == 'failed' ||
        task.status == 'cancelled') {
      return false;
    }
    if (task.status == 'paused') {
      _runningTokens[taskId]?.cancel();
      try {
        await TaskCheckpoint.delete(taskId, Workspace.instance.scratchDir);
      } catch (_) {}
      return true;
    }
    if (task.type != 'recurring' ||
        task.repeatAfter == null ||
        task.repeatAfter! <= 0) {
      await cancelRunningTask(taskId);
      return true;
    }

    _runningTokens[taskId]?.cancel();
    try {
      await TaskCheckpoint.delete(taskId, Workspace.instance.scratchDir);
    } catch (_) {}

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final nextRun = calculateNextRunAt(
      startsAt: task.startsAt,
      repeatAfter: task.repeatAfter!,
      nowMillis: nowMillis,
    );
    await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .write(
      SchedulerTasksCompanion(
        status: const Value('scheduled'),
        nextRunAt: Value(nextRun),
        updatedAt: Value(nowMillis),
      ),
    );
    await (db.update(db.schedulerTaskLogs)
          ..where((l) =>
              l.schedulerTaskId.equals(taskId) & l.status.equals('running')))
        .write(
      SchedulerTaskLogsCompanion(
        status: const Value('cancelled'),
        finishedAt: Value(nowMillis),
        errorMessage: const Value('Run skipped by user — series continues'),
        updatedAt: Value(nowMillis),
      ),
    );
    await scheduleTask(taskId);
    return true;
  }

  final StreamController<Map<String, dynamic>> _notificationClicks =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of notification clicks delivered while the app is active.
  Stream<Map<String, dynamic>> get notificationClicks => _notificationClicks.stream;

  Future<Map<String, dynamic>?>? _pendingNotificationFuture;

  /// Retrieves any cold-launch notification click intent that started the app.
  ///
  /// Reuses the in-flight lookup started early during [initialize] so cold
  /// notification routing does not wait to initiate the channel IPC after
  /// the first frame.
  Future<Map<String, dynamic>?> getPendingNotificationClick() {
    return _pendingNotificationFuture ??= _fetchPendingNotificationClick();
  }

  Future<Map<String, dynamic>?> _fetchPendingNotificationClick() async {
    AppProfile.mark('pending_channel_start');
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getPendingNotificationClick');
      AppProfile.mark('pending_channel_done found=${res != null}');
      return res;
    } catch (_) {
      AppProfile.mark('pending_channel_error');
      return null;
    }
  }

  Future<void> _loadInexactFallback() async {
    try {
      inexactFallbackActive.value =
          await db.getSetting(_kInexactFallbackKey) == 'true';
    } catch (_) {
      inexactFallbackActive.value = false;
    }
  }

  /// Records or clears the sticky inexact-fallback flag, in memory and in the
  /// settings table. Failures here must never break scheduling itself.
  Future<void> _setInexactFallback(bool value) async {
    inexactFallbackActive.value = value;
    try {
      if (value) {
        await db.setSetting(_kInexactFallbackKey, 'true');
      } else {
        await db.deleteSetting(_kInexactFallbackKey);
      }
    } catch (_) {}
  }

  /// Clears the sticky inexact-fallback flag (e.g. after the user grants exact
  /// alarms from the Manage Tasks banner).
  Future<void> clearInexactFallback() => _setInexactFallback(false);

  /// Clears the cached pending notification future after consumption.
  void clearPendingNotificationClick() {
    _pendingNotificationFuture = null;
  }

  /// Attaches method call handler to receive `executeTask` and `rescheduleAll`
  /// triggers from native Android AlarmManager / WorkManager.
  void initialize() {
    // Start pending notification lookup non-blocking before runApp()
    _pendingNotificationFuture ??= _fetchPendingNotificationClick();
    // Restore the sticky inexact-fallback flag (see [inexactFallbackActive]).
    unawaited(_loadInexactFallback());

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'executeTask':
          final args = call.arguments;
          final taskId = (args is Map) ? (args['taskId'] as int? ?? -1) : -1;
          if (taskId > 0) {
            return await executeTask(taskId);
          }
          return false;
        case 'rescheduleAll':
          return await rescheduleAllActiveTasks();
        case 'onTaskNotificationClicked':
          final args = call.arguments;
          if (args is Map) {
            _notificationClicks.add(Map<String, dynamic>.from(args));
          }
          return true;
        default:
          return null;
      }
    });
  }

  /// Schedules the next trigger for [taskId] with native Android AlarmManager.
  ///
  /// Called when a task is created, updated, resumed, or rescheduled.
  Future<void> scheduleTask(int taskId) async {
    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (task == null ||
        task.status == 'paused' ||
        task.status == 'cancelled' ||
        task.status == 'completed') {
      return;
    }

    final targetTime = task.nextRunAt ?? task.startsAt;
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    // Schedule for at least 1s into the future
    final triggerAt = targetTime > nowMillis ? targetTime : nowMillis + 1000;

    // R2-H6 + R2-M3: consult exact-alarm permission before scheduling. When
    // denied, register with JobScheduler instead of an inexact alarm — an
    // inexact alarm firing into the receiver cannot legally start the
    // foreground service on Android 12+, so the task would silently never
    // run. The job path is inexact timing by design; the banner listens to
    // [inexactFallbackActive]. Pre-S devices always permit exact alarms.
    try {
      if (!await canScheduleExactAlarms()) {
        final jobOk = await _channel.invokeMethod<bool>('scheduleJob', {
          'taskId': taskId,
          'triggerAtMillis': triggerAt,
          'title': task.title,
        });
        if (jobOk == true) {
          unawaited(_setInexactFallback(true));
          return;
        }
        // JobScheduler refused (rare): fall through to the alarm path, whose
        // receiver routes to a job at fire time if the direct start fails.
      }
    } catch (_) {
      // Permission check or job scheduling threw: fall through to alarms.
    }

    try {
      final scheduled = await _channel.invokeMethod<bool>('scheduleAlarm', {
        'taskId': taskId,
        'triggerAtMillis': triggerAt,
        'title': task.title,
      });
      if (scheduled == false) {
        debugPrint(
          '[TaskSchedulerService] Exact alarm denied for task $taskId; '
          'falling back to inexact timing. Ask the user to grant exact alarms.',
        );
        // Sticky + visible: a debugPrint is stripped in release, so without
        // this the fallback is silent. The Manage Tasks banner listens to
        // [inexactFallbackActive].
        unawaited(_setInexactFallback(true));
      } else if (scheduled == true && inexactFallbackActive.value) {
        unawaited(_setInexactFallback(false));
      }
    } catch (_) {}
  }

  /// Cancels any scheduled alarm for [taskId] with native Android AlarmManager.
  ///
  /// Called when a task is paused, cancelled, or deleted.
  Future<void> cancelTask(int taskId) async {
    try {
      await _channel.invokeMethod('cancelAlarm', {
        'taskId': taskId,
      });
    } catch (_) {}
  }

  /// Pauses all currently active ('scheduled') tasks and cancels their native alarms.
  ///
  /// Returns the number of tasks that were paused.
  Future<int> pauseAllTasks() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final activeTasks = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .get();

    if (activeTasks.isEmpty) return 0;

    await (db.update(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .write(
      SchedulerTasksCompanion(
        status: const Value('paused'),
        updatedAt: Value(nowMillis),
      ),
    );

    for (final task in activeTasks) {
      await cancelTask(task.id);
    }

    return activeTasks.length;
  }

  /// Resumes all 'paused' tasks, recalculates nextRunAt if elapsed, and schedules alarms.
  ///
  /// Returns the number of tasks that were resumed.
  Future<int> resumeAllTasks() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final pausedTasks = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('paused')))
        .get();

    if (pausedTasks.isEmpty) return 0;

    for (final task in pausedTasks) {
      final nextRun = resumedNextRunAt(task, nowMillis: nowMillis);
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(task.id)))
          .write(
        SchedulerTasksCompanion(
          status: const Value('scheduled'),
          nextRunAt: Value(nextRun),
          updatedAt: Value(nowMillis),
        ),
      );
      await scheduleTask(task.id);
    }

    return pausedTasks.length;
  }

  /// The next run time for a task being resumed from 'paused'.
  ///
  /// Shared by [resumeAllTasks] and [setPaused] so the single-task and
  /// resume-all paths cannot drift. Recomputing is required because pausing
  /// leaves `nextRunAt` untouched: a task paused for a week would otherwise
  /// resume onto a timestamp already in the past, and [scheduleTask] would
  /// clamp that to `now + 1s` — firing immediately instead of at the next
  /// cadence slot.
  static int resumedNextRunAt(SchedulerTaskRow task, {required int nowMillis}) {
    final nextRun = task.nextRunAt ?? task.startsAt;
    if (nextRun > nowMillis) return nextRun;
    if (task.type == 'recurring' &&
        task.repeatAfter != null &&
        task.repeatAfter! > 0) {
      return calculateNextRunAt(
        startsAt: task.startsAt,
        repeatAfter: task.repeatAfter!,
        nowMillis: nowMillis,
      );
    }
    // One-off task whose moment passed while paused: run shortly, not instantly.
    return nowMillis + 60000;
  }

  /// Pauses or resumes a single task, keeping [nextRunAt] and the registered
  /// alarm in sync. Single source of truth for the pause/resume transition;
  /// callers should not hand-roll the status write.
  Future<void> setPaused(int taskId, {required bool paused}) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    if (paused) {
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
          .write(
        SchedulerTasksCompanion(
          status: const Value('paused'),
          updatedAt: Value(nowMillis),
        ),
      );
      await cancelTask(taskId);
      return;
    }

    final task =
        await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
            .getSingleOrNull();
    if (task == null) return;
    final nextRun = resumedNextRunAt(task, nowMillis: nowMillis);
    await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .write(
      SchedulerTasksCompanion(
        status: const Value('scheduled'),
        nextRunAt: Value(nextRun),
        updatedAt: Value(nowMillis),
      ),
    );
    await scheduleTask(taskId);
  }

  /// In-flight reschedule guard: concurrent triggers (app start plus
  /// MY_PACKAGE_REPLACED/boot) join the same run instead of double-scheduling.
  Future<int>? _rescheduleInFlight;

  /// Re-registers all active tasks in 'scheduled' status with the native AlarmManager.
  ///
  /// Called on device boot or app startup. Concurrent callers share one run.
  Future<int> rescheduleAllActiveTasks() {
    final existing = _rescheduleInFlight;
    if (existing != null) return existing;
    final future = _runRescheduleAllActiveTasks();
    _rescheduleInFlight = future;
    future.whenComplete(() {
      if (identical(_rescheduleInFlight, future)) _rescheduleInFlight = null;
    });
    return future;
  }

  Future<int> _runRescheduleAllActiveTasks() async {
    AppProfile.mark('reschedule_start');
    await recoverStuckTasks();

    final scheduled = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('scheduled')))
        .get();

    for (final task in scheduled) {
      await scheduleTask(task.id);
    }
    AppProfile.mark('reschedule_done count=${scheduled.length}');
    return scheduled.length;
  }

  /// Checks whether exact alarms can be scheduled without permission denials.
  Future<bool> canScheduleExactAlarms() async {
    try {
      final result = await _channel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens system exact alarms settings page on Android 12+ (API 31+).
  Future<bool> openExactAlarmSettings() async {
    try {
      final result = await _channel.invokeMethod<bool>('openExactAlarmSettings');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the OS exempts the app from battery optimization (Doze network
  /// restrictions don't apply when true). Defaults to false on failure so
  /// callers check-then-prompt rather than assume.
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system battery-optimization exemption flow for this app.
  /// Full flavor fires the direct exemption prompt (declares the permission);
  /// other flavors fall back to the app-info battery page. Returns true when
  /// a settings intent was launched — not when the user granted anything.
  Future<bool> requestBatteryExemption() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('requestBatteryExemption');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Queries historical process termination reasons from Android ActivityManager
  /// (API 30+). Returns list of exit info maps containing reason, reasonName,
  /// timestamp, status, description, and importance.
  Future<List<Map<String, dynamic>>> getHistoricalExitReasons({int maxNum = 5}) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>(
        'getHistoricalExitReasons',
        {'maxNum': maxNum},
      );
      if (list == null) return const [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Attempts to launch OEM-specific autostart or background protection settings
  /// (Xiaomi/MIUI, Huawei, Oppo/Realme, Vivo, Samsung).
  /// Returns true if an OEM activity was found and started.
  Future<bool> openOemBatterySettings() async {
    try {
      final result = await _channel.invokeMethod<bool>('openOemBatterySettings');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Outcome of editing a task's schedule type/interval in settings sheets.
  /// Pure and unit-tested: the sheet must apply exactly this, so status and
  /// alarm transitions can't drift between UI and logic.
  /// - Switching to (or reconfiguring) recurring recomputes a future grid slot.
  /// - Terminal states (`failed`/`cancelled`/`completed`) auto-resurrect to
  ///   `scheduled` whenever the result is runnable; `paused`/`running` are
  ///   never touched.
  /// - One-off keeps a future `nextRunAt`, anchors a past one to now + 60s.
  static TaskEditTransition computeEditTransition({
    required String oldType,
    required String oldStatus,
    required int? oldNextRunAt,
    required int? oldRepeatAfter,
    required String newType,
    required int newRepeatAfter,
    required int startsAt,
    required int nowMillis,
  }) {
    final typeChanged = oldType != newType;
    int? nextRun = oldNextRunAt;
    String newStatus = oldStatus;
    int? outRepeatAfter;
    if (newType == 'recurring') {
      outRepeatAfter = newRepeatAfter;
      final intervalChanged = oldRepeatAfter != newRepeatAfter;
      if (typeChanged ||
          intervalChanged ||
          nextRun == null ||
          nextRun <= nowMillis) {
        nextRun = calculateNextRunAt(
          startsAt: startsAt,
          repeatAfter: newRepeatAfter,
          nowMillis: nowMillis,
        );
      }
      if (newStatus == 'failed' ||
          newStatus == 'cancelled' ||
          newStatus == 'completed') {
        newStatus = 'scheduled';
      }
    } else {
      outRepeatAfter = null;
      if (typeChanged) {
        if (nextRun != null && nextRun <= nowMillis) {
          nextRun = nowMillis + 60000;
        }
        if ((newStatus == 'failed' ||
                newStatus == 'cancelled' ||
                newStatus == 'completed') &&
            nextRun != null) {
          newStatus = 'scheduled';
        }
      }
    }
    return TaskEditTransition(
      status: newStatus,
      nextRunAt: nextRun,
      repeatAfter: outRepeatAfter,
    );
  }

  /// Calculates the next execution timestamp for a recurring task anchored at [startsAt]
  /// with interval [repeatAfter] in milliseconds (Strict Option A grid).
  ///
  /// Guarantees that the returned timestamp is strictly greater than [nowMillis]
  /// and aligns exactly to `startsAt + n * repeatAfter`, eliminating execution drift.
  static int calculateNextRunAt({
    required int startsAt,
    required int repeatAfter,
    required int nowMillis,
  }) {
    if (repeatAfter <= 0) return nowMillis + 60000;
    if (nowMillis < startsAt) return startsAt;
    final elapsed = nowMillis - startsAt;
    final n = (elapsed ~/ repeatAfter) + 1;
    // Overflow guard. `startsAt + n * repeatAfter` wraps negative for an
    // absurd repeat_after, which would be stored as a negative epoch; the
    // `targetTime > nowMillis` check in scheduleTask then fails and the task
    // fires every second forever, writing a log row and a scratch report each
    // time. The interval is also clamped at the tool boundary, but this is the
    // last line of defence for rows that predate that clamp.
    final next = startsAt + (n * repeatAfter);
    if (next <= nowMillis) return nowMillis + 60000;
    return next;
  }

  /// Sweeps tasks that were left in `running` status due to process crashes or kills.
  ///
  /// Tasks running longer than [maxRunningDuration] OR with stale heartbeats
  /// older than [staleHeartbeatDuration] are considered abandoned.
  /// If [task.notify] is true and the task was interrupted recently (within [freshKillWindow]),
  /// dispatches a failure notification to alert the user of the killed run.
  Future<int> recoverStuckTasks({
    Duration maxRunningDuration = const Duration(minutes: 15),
    Duration freshKillWindow = const Duration(hours: 4),
    Duration staleHeartbeatDuration = const Duration(seconds: 150),
  }) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMillis - maxRunningDuration.inMilliseconds;
    final freshCutoff = nowMillis - freshKillWindow.inMilliseconds;

    // Find all tasks marked running
    final runningTasks = await (db.select(db.schedulerTasks)
          ..where((t) => t.status.equals('running')))
        .get();

    if (runningTasks.isEmpty) return 0;

    final stuckTasks = <SchedulerTaskRow>[];
    final runningLogsByTask = <int, SchedulerTaskLogRow>{};

    for (final task in runningTasks) {
      // If currently active in this isolate's memory, it's alive — skip
      if (_runningTokens.containsKey(task.id)) continue;

      final latestLog = await (db.select(db.schedulerTaskLogs)
            ..where((l) =>
                l.schedulerTaskId.equals(task.id) & l.status.equals('running'))
            ..orderBy([(l) => OrderingTerm.desc(l.id)])
            ..limit(1))
          .getSingleOrNull();

      if (latestLog != null) {
        runningLogsByTask[task.id] = latestLog;
      }

      final isStaleHeartbeat = latestLog != null &&
          latestLog.lastHeartbeatAt != null &&
          (nowMillis - latestLog.lastHeartbeatAt!) >
              staleHeartbeatDuration.inMilliseconds;

      final isPastMaxDuration = task.updatedAt < cutoff;

      if (isPastMaxDuration || isStaleHeartbeat) {
        stuckTasks.add(task);
      }
    }

    if (stuckTasks.isEmpty) return 0;

    // Query historical OS exit reasons to diagnose why the process was killed
    final exitReasons = await getHistoricalExitReasons(maxNum: 5);

    for (final task in stuckTasks) {
      final log = runningLogsByTask[task.id];
      final taskActivityTime =
          log?.lastHeartbeatAt ?? task.lastRunAt ?? task.updatedAt;

      Map<String, dynamic>? matchedExit;
      for (final exit in exitReasons) {
        final exitTs = exit['timestamp'] as int? ?? 0;
        if (exitTs > 0 &&
            (exitTs - taskActivityTime).abs() <
                const Duration(minutes: 10).inMilliseconds) {
          matchedExit = exit;
          break;
        }
      }

      final String reasonDiagnostic;
      if (matchedExit != null) {
        final rName = matchedExit['reasonName'] as String? ?? 'SYSTEM_KILL';
        final desc = (matchedExit['description'] as String?)?.trim();
        reasonDiagnostic =
            'Task execution interrupted or killed by system ($rName${desc != null && desc.isNotEmpty ? ': $desc' : ''}).';
      } else {
        reasonDiagnostic = 'Task execution interrupted or killed by system.';
      }

      // Check for resumable checkpoint. Resume attempts are counted in a
      // sidecar file (not the checkpoint itself) so the cap survives the
      // fresh starts that delete checkpoints — otherwise an always-crashing
      // task would resume-cycle forever across recoveries.
      final checkpoint = await TaskCheckpoint.load(
        task.id,
        Workspace.instance.scratchDir,
      );
      var canResume = false;
      if (checkpoint != null) {
        final attempts = await TaskCheckpoint.noteResumeAttempt(
          task.id,
          Workspace.instance.scratchDir,
        );
        if (attempts <= TaskCheckpoint.maxResumes) {
          canResume = true;
        } else {
          // Cap exhausted: drop the checkpoint so this and future recoveries
          // take the normal path instead of cycling.
          await TaskCheckpoint.delete(task.id, Workspace.instance.scratchDir);
        }
      }

      if (canResume && checkpoint != null) {
        // Auto-resume from checkpoint (+30s delay)
        final resumeRunAt = nowMillis + 30000;
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(task.id)))
            .write(
          SchedulerTasksCompanion(
            status: const Value('scheduled'),
            nextRunAt: Value(resumeRunAt),
            updatedAt: Value(nowMillis),
          ),
        );
        await scheduleTask(task.id);

        await (db.update(db.schedulerTaskLogs)
              ..where((l) =>
                  l.schedulerTaskId.equals(task.id) &
                  l.status.equals('running')))
            .write(
          SchedulerTaskLogsCompanion(
            status: const Value('timeout'),
            finishedAt: Value(nowMillis),
            errorMessage: Value(
              '$reasonDiagnostic Resuming from checkpoint (turn ${checkpoint.turn}).',
            ),
            updatedAt: Value(nowMillis),
          ),
        );
      } else {
        if (task.type == 'recurring' &&
            task.repeatAfter != null &&
            task.repeatAfter! > 0) {
          final nextRun = calculateNextRunAt(
            startsAt: task.startsAt,
            repeatAfter: task.repeatAfter!,
            nowMillis: nowMillis,
          );
          await (db.update(db.schedulerTasks)
                ..where((t) => t.id.equals(task.id)))
              .write(
            SchedulerTasksCompanion(
              status: const Value('scheduled'),
              nextRunAt: Value(nextRun),
              updatedAt: Value(nowMillis),
            ),
          );
          await scheduleTask(task.id);
        } else {
          await (db.update(db.schedulerTasks)
                ..where((t) => t.id.equals(task.id)))
              .write(
            SchedulerTasksCompanion(
              status: const Value('failed'),
              updatedAt: Value(nowMillis),
            ),
          );
        }

        await (db.update(db.schedulerTaskLogs)
              ..where((l) =>
                  l.schedulerTaskId.equals(task.id) &
                  l.status.equals('running')))
            .write(
          SchedulerTaskLogsCompanion(
            status: const Value('timeout'),
            finishedAt: Value(nowMillis),
            errorMessage: Value(reasonDiagnostic),
            updatedAt: Value(nowMillis),
          ),
        );
      }

      // Notify on fresh kill if notifications are enabled for the task.
      // Stale boot recoveries beyond the freshKillWindow are recovered silently.
      final isFreshKill = task.updatedAt >= freshCutoff ||
          (task.lastRunAt != null && task.lastRunAt! >= freshCutoff);
      if (task.notify && isFreshKill) {
        try {
          final notifBody = (canResume && checkpoint != null)
              ? 'Task interrupted. Resuming from checkpoint (turn ${checkpoint.turn})...'
              : 'Task execution was killed or interrupted by the system.';
          await notificationService.showNotification(
            id: task.id,
            title: 'Task Interrupted: ${task.title}',
            body: notifBody,
            isSuccess: false,
          );
        } catch (_) {}
      }
    }
    return stuckTasks.length;
  }

  /// Entry point invoked when AlarmManager or WorkManager fires for [taskId].
  ///
  /// Runs an isolated, headless agent turn, saves the markdown report to `.scratch/`,
  /// updates database state and execution logs, and dispatches a system notification if enabled.
  Future<bool> executeTask(
    int taskId, {
    bool allowCompleted = false,
    bool suppressNotification = false,
    AgentRunner? runner,
    Directory? scratchDirectory,
    Duration timeout = const Duration(minutes: 10),
    CancelToken? cancelToken,
  }) async {
    // 1. Allowlist guard: only scheduled tasks (or failed tasks for retry) can be executed.
    // Rejects already running tasks, paused, and cancelled tasks.
    // Completed tasks are rejected unless allowCompleted is true (e.g. manual UI trigger).
    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    final allowedStatuses = allowCompleted
        ? const ['scheduled', 'failed', 'completed']
        : const ['scheduled', 'failed'];
    if (task == null || !allowedStatuses.contains(task.status)) {
      return false;
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    // 2. Atomic claim: transition from allowed statuses to 'running'.
    // Prevents double-execution if AlarmManager and WorkManager fire concurrently.
    final claimedRows = await (db.update(db.schedulerTasks)
          ..where((t) =>
              t.id.equals(taskId) &
              t.status.isIn(allowedStatuses)))
        .write(
      SchedulerTasksCompanion(
        status: const Value('running'),
        lastRunAt: Value(nowMillis),
        totalRuns: Value(task.totalRuns + 1),
        updatedAt: Value(nowMillis),
      ),
    );
    if (claimedRows == 0) {
      return false;
    }

    if (kDebugMode) {
      TaskProgressService.instance.emit(
        TaskProgressEvent(
          taskId: taskId,
          stage: TaskExecutionStage.starting,
          message: 'Task #${task.id} started: "${task.title}"',
        ),
      );
    }

    final scheduledFor = task.nextRunAt ?? task.startsAt;
    // The task can be deleted between the claim above and this insert, which
    // would violate the log FK. Distinguish that (quiet exit, nothing to
    // show) from a transient DB failure (mark failed so it stays visible).
    int logId;
    try {
      logId = await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: scheduledFor,
          startedAt: Value(nowMillis),
          status: 'running',
          lastHeartbeatAt: Value(nowMillis),
          currentStep: const Value('starting'),
          createdAt: nowMillis,
          updatedAt: nowMillis,
        ),
      );
    } catch (_) {
      final stillThere = await (db.select(db.schedulerTasks)
            ..where((t) => t.id.equals(taskId)))
          .getSingleOrNull();
      if (stillThere == null) return false;
      final finishMillis = DateTime.now().millisecondsSinceEpoch;
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        SchedulerTasksCompanion(
          status: const Value('failed'),
          failures: Value(task.failures + 1),
          updatedAt: Value(finishMillis),
        ),
      );
      if (task.notify) {
        try {
          await notificationService.showNotification(
            id: taskId,
            title: 'Task Failed: ${task.title}',
            body: 'Could not start execution (database error).',
            isSuccess: false,
          );
        } catch (_) {}
      }
      return false;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(task.payloadJson) as Map<String, dynamic>;
    } catch (_) {
      payload = {};
    }
    final prompt = (payload['prompt'] as String?)?.trim() ?? task.title;

    AgentRunner? agentRunner = runner;
    LlmClient? locallyCreatedClient;
    if (agentRunner == null) {
      try {
        final settings = AppSettingsService.instance;
        final targetProviderId = payload['providerId'] as String?;
        final targetModel = (payload['model'] as String?)?.trim();

        // Resolve provider (override or active default)
        LlmProvider provider = settings.activeProvider;
        if (targetProviderId != null && targetProviderId.isNotEmpty) {
          final found = settings.providers.where((p) => p.id == targetProviderId).firstOrNull;
          if (found != null) {
            provider = found;
          }
        }

        final model = (targetModel != null && targetModel.isNotEmpty)
            ? targetModel
            : settings.selectedModel;

        final apiKey = settings.resolveApiKey(provider);
        locallyCreatedClient = LlmClient(
          config: LlmConfig(
            baseUrl: provider.baseUrl.isNotEmpty
                ? provider.baseUrl
                : provider.defaultBaseUrl,
            apiKey: apiKey,
            model: model,
          ),
          // Autonomous background runs use cellular-aware backoff (2s, 4s, 8s, 16s, 32s)
          // and a relaxed 120s inactivity watchdog so thinking models and mobile radio
          // latency do not trigger premature resets.
          maxAttempts: 5,
          streamInactivityTimeout: const Duration(seconds: 120),
          streamTimeout: const Duration(seconds: 90),
          timeout: const Duration(seconds: 120),
          backoffDuration: (attempt) => Duration(
            seconds: 2 * (1 << (attempt - 1 >= 4 ? 4 : attempt - 1)),
          ),
        );
        agentRunner = AgentRunner(
          llm: locallyCreatedClient,
          workingDirectory: WorkingDirectory(Workspace.instance.documentsDir),
          selectedModel: model,
        );
      } catch (_) {}
    }

    if (agentRunner == null) {
      final finishMillis = DateTime.now().millisecondsSinceEpoch;
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          finishedAt: Value(finishMillis),
          status: const Value('failed'),
          errorMessage: const Value('No LLM client configured for background task execution.'),
          updatedAt: Value(finishMillis),
        ),
      );
      await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
        SchedulerTasksCompanion(
          status: const Value('failed'),
          failures: Value(task.failures + 1),
          updatedAt: Value(finishMillis),
        ),
      );
      if (task.notify) {
        try {
          await notificationService.showNotification(
            id: taskId,
            title: 'Task Failed: ${task.title}',
            body: 'No LLM client configured for background task execution.',
          );
        } catch (_) {}
      }
      return false;
    }

    // Registered before the pre-flight probe (not after it) so a user skip
    // during the ~15s probe window actually cancels something instead of
    // hitting a null-safe no-op while the run proceeds anyway.
    final effectiveCancelToken = cancelToken ?? CancelToken();
    _runningTokens[taskId] = effectiveCancelToken;

    // Pre-flight check: give dormant cellular radio up to 15s to transition
    // from RRC_IDLE and resolve DNS before starting the agent loop.
    if (runner == null && locallyCreatedClient != null) {
      final host = Uri.tryParse(locallyCreatedClient.config.baseUrl)?.host;
      final networkReady = await probeNetworkReadiness(
        host: host != null && host.isNotEmpty ? host : 'openrouter.ai',
      );
      if (!networkReady) {
        final finishMillis = DateTime.now().millisecondsSinceEpoch;
        await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
          SchedulerTaskLogsCompanion(
            finishedAt: Value(finishMillis),
            status: const Value('failed'),
            errorMessage: const Value('Network unreachable (cellular radio did not connect within 15s).'),
            updatedAt: Value(finishMillis),
          ),
        );
        // Mirror the normal failure transition: a transient radio blip must
        // not kill a recurring series. Reschedule unless retries are
        // exhausted, exactly like a mid-run network failure does.
        final probeFailures = task.failures + 1;
        final probeMaxRetries = task.retriesPerTurn;
        final probeExceeded =
            probeMaxRetries > 0 && probeFailures >= probeMaxRetries;
        if (task.type == 'recurring' &&
            task.repeatAfter != null &&
            task.repeatAfter! > 0 &&
            !probeExceeded) {
          final nextRun = calculateNextRunAt(
            startsAt: task.startsAt,
            repeatAfter: task.repeatAfter!,
            nowMillis: finishMillis,
          );
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
            SchedulerTasksCompanion(
              status: const Value('scheduled'),
              nextRunAt: Value(nextRun),
              failures: Value(probeFailures),
              updatedAt: Value(finishMillis),
            ),
          );
          await scheduleTask(taskId);
        } else {
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId))).write(
            SchedulerTasksCompanion(
              status: const Value('failed'),
              failures: Value(probeFailures),
              updatedAt: Value(finishMillis),
            ),
          );
        }
        if (task.notify) {
          try {
            await notificationService.showNotification(
              id: taskId,
              title: 'Task Failed: ${task.title}',
              body: 'Network unreachable (cellular radio did not connect).',
            );
          } catch (_) {}
        }
        return false;
      }
    }

    HeadlessRunResult result;
    var isTimeout = false;

    // Live-run telemetry for the `running` log row: heartbeat + current step,
    // throttled so a tool-heavy turn doesn't hammer the database. Written
    // through the run's own isolate, so a *stale* heartbeat on a `running` row
    // unambiguously means the runner died without writing its outcome — the
    // exact fossil that previously needed a manual skip to clear. Step text is
    // tool names and turn counts only, never prompts or outputs.
    var lastBeatMillis = nowMillis;
    String? lastStep;
    void recordBeat(String step) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastBeatMillis < 15000 && step == lastStep) return;
      lastStep = step;
      lastBeatMillis = now;
      unawaited(() async {
        try {
          await (db.update(db.schedulerTaskLogs)
                ..where((l) => l.id.equals(logId)))
              .write(
            SchedulerTaskLogsCompanion(
              lastHeartbeatAt: Value(now),
              currentStep: Value(step),
              updatedAt: Value(now),
            ),
          );
        } catch (_) {}
      }());
    }

    try {
      result = await agentRunner
          .runHeadless(
            taskId: taskId,
            prompt: prompt,
            taskTitle: task.title,
            scratchDirectory: scratchDirectory,
            db: db,
            schedulerService: this,
            cancelToken: effectiveCancelToken,
            enableBrowser: payload['enableBrowser'] == true,
            onEvent: (event) {
              // Heartbeat only: short step text, never prompts or outputs.
              String step;
              if (event is AgentThinking) {
                step = 'turn ${event.turn} · thinking';
              } else if (event is AgentToolCallStarting) {
                step = 'turn ${event.turn} · tool ${event.call.name}';
              } else if (event is AgentToolCall) {
                step = 'turn ${event.turn} · ${event.call.name} done';
              } else if (event is AgentCompacting) {
                step = 'compacting context';
              } else {
                step = 'context compacted';
              }
              recordBeat(
                step.length > 120 ? step.substring(0, 120) : step,
              );
            },
          )
          .timeout(timeout);
    } on TimeoutException {
      isTimeout = true;
      effectiveCancelToken.cancel();
      result = HeadlessRunResult(
        ok: false,
        output: '',
        errorMessage: 'Task timed out after ${timeout.inSeconds} seconds.',
      );
    } catch (e) {
      result = HeadlessRunResult(
        ok: false,
        output: '',
        errorMessage: e.toString(),
      );
    } finally {
      _runningTokens.remove(taskId);
      locallyCreatedClient?.close();
    }

    final finishMillis = DateTime.now().millisecondsSinceEpoch;

    // Re-read: the task may have been deleted or cancelled from another
    // isolate while running (a UI cancel cannot reach this isolate's token).
    // Deleted → stay silent (no row to update, no notification for a task
    // the user removed). Cancelled → honor it instead of overwriting.
    final freshTask = await (db.select(db.schedulerTasks)
          ..where((t) => t.id.equals(taskId)))
        .getSingleOrNull();
    if (freshTask == null) return false;

    // Guard: every write below used to be a bare await, and a single throw
    // (teardown, locked DB, full disk) froze the row on `running` forever.
    // The fallback only touches rows still `running`, so correctly written
    // outcomes are never clobbered.
    final isSuccess = result.ok;
    final outcome = await (() async {
    if ((effectiveCancelToken.isCancelled && !isTimeout) ||
        freshTask.status == 'cancelled') {
      // Never overwrite a status someone else already moved to (e.g.
      // skipCurrentRun rescheduled the series while this run aborted).
      if (freshTask.status == 'running') {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
          SchedulerTasksCompanion(
            status: const Value('cancelled'),
            nextRunAt: const Value(null),
            updatedAt: Value(finishMillis),
          ),
        );
        await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
          SchedulerTaskLogsCompanion(
            status: const Value('cancelled'),
            finishedAt: Value(finishMillis),
            errorMessage: const Value('Cancelled by user'),
            updatedAt: Value(finishMillis),
          ),
        );
      }
      return (proceed: false, summary: '');
    }

    // The runner guarantees reportPath (save_report tool or final-answer
    // fallback). Verify the file actually exists; prune older reports for
    // this task so recurring runs don't fill scratch unboundedly.
    String? reportPath = result.reportPath;
    final scratch = scratchDirectory ?? Workspace.instance.scratchDir;
    try {
      if (reportPath != null && !File(reportPath).existsSync()) {
        reportPath = null;
      }
    } catch (_) {}

    final relativeReportPath = reportPath != null
        ? toScratchRelative(reportPath, scratch)
        : null;
    final relativeLinkedFiles = result.linkedFiles
        .map((f) => toScratchRelative(f, scratch))
        .toList();

    // Extract one-line summary for logs and notification
    final summary = result.output.trim().split('\n').firstWhere(
      (line) => line.trim().isNotEmpty,
      orElse: () => isSuccess
          ? 'Task completed successfully.'
          : (result.errorMessage ?? 'Task failed.'),
    );

    final logStatus = isTimeout ? 'timeout' : (isSuccess ? 'success' : 'failed');

    await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
      SchedulerTaskLogsCompanion(
        finishedAt: Value(finishMillis),
        status: Value(logStatus),
        outputFilePath: Value(relativeReportPath),
        linkedFiles: Value(jsonEncode(relativeLinkedFiles)),
        summary: Value(summary),
        errorMessage: Value(result.errorMessage),
        updatedAt: Value(finishMillis),
      ),
    );

    if (kDebugMode) {
      TaskProgressService.instance.emit(
        TaskProgressEvent(
          taskId: taskId,
          stage: isSuccess ? TaskExecutionStage.completed : TaskExecutionStage.failed,
          message: isSuccess
              ? 'Task #${freshTask.id} completed successfully'
              : (result.errorMessage ?? 'Task #${freshTask.id} failed'),
          isError: !isSuccess,
        ),
      );
    }

    try {
      await _pruneOldReports(scratch, taskId, keep: 10, keepPath: reportPath);
    } catch (_) {}

    if (isSuccess) {
      if (freshTask.type == 'recurring' && freshTask.repeatAfter != null && freshTask.repeatAfter! > 0) {
        final nextRun = calculateNextRunAt(
          startsAt: freshTask.startsAt,
          repeatAfter: freshTask.repeatAfter!,
          nowMillis: finishMillis,
        );
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
          SchedulerTasksCompanion(
            status: const Value('scheduled'),
            nextRunAt: Value(nextRun),
            failures: const Value(0),
            updatedAt: Value(finishMillis),
          ),
        );
        await scheduleTask(taskId);
      } else {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
          SchedulerTasksCompanion(
            status: const Value('completed'),
            nextRunAt: const Value(null),
            failures: const Value(0),
            updatedAt: Value(finishMillis),
          ),
        );
      }
    } else {
      if (GrantFlowService.isDozeSuspectedFailure(
        result.errorMessage,
        isTimeout: isTimeout,
      )) {
        unawaited(GrantFlowService.rearmOnFailure(
          db,
          errorMessage: result.errorMessage,
          isTimeout: isTimeout,
        ));
      }
      final newFailures = freshTask.failures + 1;
      final maxRetries = freshTask.retriesPerTurn;
      final hasExceededRetries = maxRetries > 0 && newFailures >= maxRetries;

      if (freshTask.type == 'recurring' && freshTask.repeatAfter != null && freshTask.repeatAfter! > 0) {
        if (hasExceededRetries) {
          // Exceeded max consecutive retries; mark as failed until user intervenes
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
            SchedulerTasksCompanion(
              status: const Value('failed'),
              nextRunAt: const Value(null),
              failures: Value(newFailures),
              updatedAt: Value(finishMillis),
            ),
          );
        } else {
          // Reschedule for next regular interval so transient network glitches do not kill recurring tasks
          final nextRun = calculateNextRunAt(
            startsAt: freshTask.startsAt,
            repeatAfter: freshTask.repeatAfter!,
            nowMillis: finishMillis,
          );
          await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
            SchedulerTasksCompanion(
              status: const Value('scheduled'),
              nextRunAt: Value(nextRun),
              failures: Value(newFailures),
              updatedAt: Value(finishMillis),
            ),
          );
          await scheduleTask(taskId);
        }
      } else {
        await (db.update(db.schedulerTasks)..where((t) => t.id.equals(taskId) & t.updatedAt.equals(nowMillis))).write(
          SchedulerTasksCompanion(
            status: const Value('failed'),
            nextRunAt: const Value(null),
            failures: Value(newFailures),
            updatedAt: Value(finishMillis),
          ),
        );
      }
    }
    return (proceed: true, summary: summary);
    })().catchError((_) async {
      // Best-effort terminal write: move the fossil, touch nothing else.
      final failMillis = DateTime.now().millisecondsSinceEpoch;
      final failStatus = isTimeout ? 'timeout' : 'failed';
      try {
        await (db.update(db.schedulerTaskLogs)
              ..where((l) => l.id.equals(logId) & l.status.equals('running')))
            .write(
          SchedulerTaskLogsCompanion(
            finishedAt: Value(failMillis),
            status: Value(failStatus),
            errorMessage: Value(result.errorMessage ??
                'Run finished but its outcome could not be recorded.'),
            updatedAt: Value(failMillis),
          ),
        );
      } catch (_) {}
      try {
        await (db.update(db.schedulerTasks)
              ..where((t) => t.id.equals(taskId) & t.status.equals('running')))
            .write(
          SchedulerTasksCompanion(
            status: const Value('failed'),
            nextRunAt: const Value(null),
            updatedAt: Value(failMillis),
          ),
        );
      } catch (_) {}
      return (proceed: false, summary: '');
    });
    if (!outcome.proceed) return false;
    final summary = outcome.summary;

    if (freshTask.notify && !suppressNotification) {
      bool shown = false;
      String skipReason = '';
      try {
        final notifTitle = isSuccess
            ? 'Task Completed: ${freshTask.title}'
            : 'Task Failed: ${freshTask.title}';
        final notifBody = summary.length > 250
            ? '${summary.substring(0, 247)}...'
            : summary;
        shown = await notificationService.showNotification(
          id: taskId,
          title: notifTitle,
          body: notifBody,
          isSuccess: isSuccess,
        );
        if (!shown) {
          skipReason = 'suppressed (permission denied or channel missing)';
        }
      } catch (e) {
        skipReason = 'threw: $e';
      }
      // Record honestly whether the shade actually got the notification --
      // marking unsent rows as sent makes missing notifications undebuggable.
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          notificationSent: Value(shown ? 1 : 0),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      if (!shown) {
        debugPrint(
          '[TaskScheduler] Notification not shown for task $taskId: $skipReason',
        );
      }
    } else {
      debugPrint(
        suppressNotification
            ? '[TaskScheduler] Notification suppressed for manual on-the-fly run of task $taskId.'
            : '[TaskScheduler] Notifications disabled for task $taskId; skipping.',
      );
      // Silent runs have notify: false and no notification is posted.
      // Mark notificationSeen: 1 so they do not pollute the unread tab or badge count.
      await (db.update(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).write(
        SchedulerTaskLogsCompanion(
          notificationSent: const Value(0),
          notificationSeen: const Value(1),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
    }

    return isSuccess;
  }

  /// Deletes older reports and linked files in [scratch] for runs beyond the newest
  /// [keep] runs so recurring tasks don't fill the disk unboundedly.
  /// Never deletes the file at [keepPath] (the current run's report).
  Future<void> _pruneOldReports(Directory scratch, int taskId,
      {int keep = 10, String? keepPath}) async {
    try {
      if (!scratch.existsSync()) return;

      // Query database logs for this task to prune reports & linked_files for runs beyond the newest [keep].
      final logs = await (db.select(db.schedulerTaskLogs)
            ..where((l) => l.schedulerTaskId.equals(taskId))
            ..orderBy([(l) => OrderingTerm.desc(l.createdAt)]))
          .get();

      final keepAbs = <String>{};
      if (keepPath != null) {
        final keepResolved = resolveReportPath(keepPath, scratch);
        if (keepResolved.isNotEmpty && isScratchOwned(keepResolved, scratch)) {
          keepAbs.add(keepResolved);
        }
      }

      bool logHasFiles(SchedulerTaskLogRow log) =>
          (log.outputFilePath != null && log.outputFilePath!.isNotEmpty) ||
          parseLinkedFiles(log.linkedFiles).isNotEmpty;

      // Only runs that actually produced files consume keep slots: failure
      // rows (null report, no links) must not evict older good reports.
      final logsWithFiles = logs.where(logHasFiles).toList();
      for (final activeLog in logsWithFiles.take(keep)) {
        if (activeLog.outputFilePath != null && activeLog.outputFilePath!.isNotEmpty) {
          final abs = resolveReportPath(activeLog.outputFilePath!, scratch);
          if (abs.isNotEmpty && isScratchOwned(abs, scratch)) keepAbs.add(abs);
        }
        for (final rel in parseLinkedFiles(activeLog.linkedFiles)) {
          final abs = resolveReportPath(rel, scratch);
          if (abs.isNotEmpty && isScratchOwned(abs, scratch)) keepAbs.add(abs);
        }
      }

      for (final oldLog in logsWithFiles.skip(keep)) {
        if (oldLog.outputFilePath != null && oldLog.outputFilePath!.isNotEmpty) {
          final abs = resolveReportPath(oldLog.outputFilePath!, scratch);
          if (abs.isNotEmpty &&
              isScratchOwned(abs, scratch) &&
              !keepAbs.contains(abs)) {
            try {
              final f = File(abs);
              if (f.existsSync()) f.deleteSync();
            } catch (_) {}
          }
        }
        for (final rel in parseLinkedFiles(oldLog.linkedFiles)) {
          final abs = resolveReportPath(rel, scratch);
          if (abs.isNotEmpty &&
              isScratchOwned(abs, scratch) &&
              !keepAbs.contains(abs)) {
            try {
              final f = File(abs);
              if (f.existsSync()) f.deleteSync();
            } catch (_) {}
          }
        }
      }

      // Legacy fallback: if there are no logs matching this task, prune legacy task-$taskId-* files directly.
      if (logs.isEmpty) {
        final prefix = 'task-$taskId-';
        final legacyFiles = scratch
            .listSync()
            .whereType<File>()
            .where((f) {
              final name = f.uri.pathSegments.last;
              return name.startsWith(prefix) &&
                  (name.endsWith('.md') || name.endsWith('.html'));
            })
            .toList();
        legacyFiles.sort((a, b) {
          DateTime aTime, bTime;
          try {
            aTime = a.lastModifiedSync();
          } catch (_) {
            aTime = DateTime.fromMillisecondsSinceEpoch(0);
          }
          try {
            bTime = b.lastModifiedSync();
          } catch (_) {
            bTime = DateTime.fromMillisecondsSinceEpoch(0);
          }
          return bTime.compareTo(aTime);
        });
        for (final f in legacyFiles.skip(keep)) {
          if (!keepAbs.contains(f.path)) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
}
