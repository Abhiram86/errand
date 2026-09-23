import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/database.dart';
import '../../theme/app_colors.dart';

/// Granular Countdown Timing Widget (P10: Replaces screen-wide 1s rebuild ticker).
class TaskTimingInfo extends StatefulWidget {
  final SchedulerTaskRow task;

  const TaskTimingInfo({super.key, required this.task});

  @override
  State<TaskTimingInfo> createState() => _TaskTimingInfoState();
}

class _TaskTimingInfoState extends State<TaskTimingInfo> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant TaskTimingInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.nextRunAt != widget.task.nextRunAt ||
        oldWidget.task.startsAt != widget.task.startsAt) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;

    final task = widget.task;
    if (task.status != 'scheduled') return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRun = task.nextRunAt ?? task.startsAt;
    final diff = nextRun - now;

    if (diff <= 0) return;

    // Use 1s ticks for sub-60s horizons; 15s ticks for anything further out.
    final interval = diff <= 60000
        ? const Duration(seconds: 1)
        : const Duration(seconds: 15);

    _timer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      setState(() {});
      final currentDiff = (widget.task.nextRunAt ?? widget.task.startsAt) -
          DateTime.now().millisecondsSinceEpoch;
      if (currentDiff <= 60000 && interval.inSeconds > 1) {
        _syncTimer();
      } else if (currentDiff <= 0) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
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
}
