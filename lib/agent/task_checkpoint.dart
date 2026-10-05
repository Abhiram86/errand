import 'dart:convert';
import 'dart:io';

/// Encapsulates per-turn execution state for a headless scheduled task.
///
/// If Android's Low Memory Killer (LMK), a battery manager, or a process death
/// terminates the runner isolate mid-flight, this checkpoint allows the task to
/// resume seamlessly from its last completed turn instead of restarting from scratch
/// and duplicating side effects.
class TaskCheckpoint {
  final int taskId;
  final int turn;
  final int resumeCount;
  final int updatedAt;
  final List<Map<String, dynamic>> messages;
  final String? collectedReportPath;
  final List<String> linkedFiles;

  const TaskCheckpoint({
    required this.taskId,
    required this.turn,
    required this.resumeCount,
    required this.updatedAt,
    required this.messages,
    this.collectedReportPath,
    this.linkedFiles = const [],
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'turn': turn,
    'resumeCount': resumeCount,
    'updatedAt': updatedAt,
    'messages': messages,
    if (collectedReportPath != null) 'collectedReportPath': collectedReportPath,
    'linkedFiles': linkedFiles,
  };

  factory TaskCheckpoint.fromJson(Map<String, dynamic> json) {
    return TaskCheckpoint(
      taskId: json['taskId'] as int? ?? -1,
      turn: json['turn'] as int? ?? 0,
      resumeCount: json['resumeCount'] as int? ?? 0,
      updatedAt: json['updatedAt'] as int? ?? 0,
      messages: (json['messages'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
      collectedReportPath: json['collectedReportPath'] as String?,
      linkedFiles: (json['linkedFiles'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  /// Returns the canonical checkpoint file path within [scratchDir].
  static File fileFor(int taskId, Directory scratchDir) {
    return File('${scratchDir.path}/task-$taskId-checkpoint.json');
  }

  /// Atomically writes the checkpoint to [scratchDir] using a `.tmp` file and rename.
  Future<void> save(Directory scratchDir) async {
    try {
      if (!scratchDir.existsSync()) {
        scratchDir.createSync(recursive: true);
      }
      final target = fileFor(taskId, scratchDir);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      if (target.existsSync()) {
        target.deleteSync();
      }
      await tmp.rename(target.path);
    } catch (_) {}
  }

  /// Loads an existing checkpoint for [taskId] if available and within [maxAge].
  /// Stale checkpoints (older than [maxAge]) are automatically pruned.
  static Future<TaskCheckpoint?> load(
    int taskId,
    Directory scratchDir, {
    Duration maxAge = const Duration(hours: 4),
  }) async {
    try {
      final file = fileFor(taskId, scratchDir);
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final checkpoint = TaskCheckpoint.fromJson(decoded);
      if (checkpoint.taskId != taskId) return null;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (checkpoint.updatedAt > 0 &&
          (now - checkpoint.updatedAt) > maxAge.inMilliseconds) {
        await delete(taskId, scratchDir);
        return null;
      }
      return checkpoint;
    } catch (_) {
      return null;
    }
  }

  /// Removes the checkpoint and any leftover `.tmp` file for [taskId].
  static Future<void> delete(int taskId, Directory scratchDir) async {
    try {
      final file = fileFor(taskId, scratchDir);
      if (file.existsSync()) {
        file.deleteSync();
      }
      final tmp = File('${file.path}.tmp');
      if (tmp.existsSync()) {
        tmp.deleteSync();
      }
      // The resume counter dies with the checkpoint: success and cancel both
      // funnel through here, so only uninterrupted crash cycles accumulate.
      final counter = counterFileFor(taskId, scratchDir);
      if (counter.existsSync()) {
        counter.deleteSync();
      }
    } catch (_) {}
  }

  /// Max auto-resumes per task across ALL runs (not per checkpoint file).
  static const int maxResumes = 2;

  /// Sidecar resume-attempt counter for [taskId].
  ///
  /// A counter inside the checkpoint file itself would reset every time a
  /// fresh start deletes it, letting an always-crashing task cycle forever
  /// (fresh → crash → recover → fresh → …). This file survives checkpoint
  /// deletion and is cleared only by [delete] (success/cancel), so the cap
  /// holds across recoveries.
  static File counterFileFor(int taskId, Directory scratchDir) {
    return File('${scratchDir.path}/task-$taskId-resumecount');
  }

  /// Records one auto-resume attempt; returns the new total (1-based).
  /// Call only when actually resuming from an existing checkpoint.
  static Future<int> noteResumeAttempt(int taskId, Directory scratchDir) async {
    var count = 0;
    try {
      final file = counterFileFor(taskId, scratchDir);
      if (file.existsSync()) {
        count = int.tryParse((await file.readAsString()).trim()) ?? 0;
      }
      count++;
      await file.writeAsString('$count', flush: true);
    } catch (_) {}
    return count;
  }
}
