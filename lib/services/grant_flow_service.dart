import 'dart:async';

import 'package:flutter/material.dart';

import '../services/database.dart';
import '../services/task_scheduler_service.dart';
import '../theme/app_colors.dart';

/// Which grant the creation-time flow should ask for next.
enum GrantStep { exactAlarm, batteryExemption }

/// Creation-time grant flow (P13.4 item 6): when the first scheduled tasks
/// appear, grants are asked where the user is — not in Manage Tasks.
/// Exact alarm first (nothing to exempt if nothing fires), then battery
/// exemption. Each step shows once; denial cools down until a
/// Doze-suspected failure re-arms it (failure-fix path, separate).
class GrantFlowService {
  GrantFlowService._();

  static const String _kExactPrompted = 'pref.grant.exact_alarm.prompted';
  static const String _kBatteryPrompted = 'pref.grant.battery.prompted';

  /// Pure decision: which step (if any) to prompt for next, given current
  /// grant states and prompt history. Unit-tested.
  static GrantStep? nextStep({
    required bool exactGranted,
    required bool batteryExempt,
    required bool exactPrompted,
    required bool batteryPrompted,
  }) {
    if (!exactGranted && !exactPrompted) return GrantStep.exactAlarm;
    if (!batteryExempt && !batteryPrompted) return GrantStep.batteryExemption;
    return null;
  }

  static Future<bool> _wasPrompted(
      ErrandDatabase db, String key) async {
    return await db.getSetting(key) == '1';
  }

  static Future<void> _markPrompted(
      ErrandDatabase db, String key) async {
    await db.setSetting(key, '1');
  }

  /// Entry point: call (fire-and-forget) when a scheduled task is created.
  /// Checks grant states and shows the next unprompted step as a bottom
  /// sheet. Never throws — failures stay silent, the toast already fired.
  static Future<void> maybePromptAfterTaskCreated(
    BuildContext context, {
    ErrandDatabase? database,
    TaskSchedulerService? scheduler,
  }) async {
    try {
      final db = database ?? ErrandDatabase.instance;
      final svc = scheduler ?? TaskSchedulerService.instance;

      final exactGranted = await svc.canScheduleExactAlarms();
      final batteryExempt = await svc.isIgnoringBatteryOptimizations();
      final exactPrompted = await _wasPrompted(db, _kExactPrompted);
      final batteryPrompted = await _wasPrompted(db, _kBatteryPrompted);

      var step = nextStep(
        exactGranted: exactGranted,
        batteryExempt: batteryExempt,
        exactPrompted: exactPrompted,
        batteryPrompted: batteryPrompted,
      );
      while (step != null) {
        if (!context.mounted) return;
        final proceeded = await _showStepSheet(context, step, svc);
        await _markPrompted(
          db,
          step == GrantStep.exactAlarm ? _kExactPrompted : _kBatteryPrompted,
        );
        if (!proceeded) return;
        // Re-evaluate: the user may have granted, changing the next step.
        final reExact = await svc.canScheduleExactAlarms();
        final reBattery = await svc.isIgnoringBatteryOptimizations();
        final reExactPrompted = await _wasPrompted(db, _kExactPrompted);
        final reBatteryPrompted = await _wasPrompted(db, _kBatteryPrompted);
        step = nextStep(
          exactGranted: reExact,
          batteryExempt: reBattery,
          exactPrompted: reExactPrompted,
          batteryPrompted: reBatteryPrompted,
        );
        if (!context.mounted) return;
      }
    } catch (_) {}
  }

  /// Shows one grant step. Returns true when the sheet was dismissed via
  /// Allow (flow may continue to the next step), false on skip/dismiss.
  static Future<bool> _showStepSheet(
    BuildContext context,
    GrantStep step,
    TaskSchedulerService svc,
  ) async {
    final isAlarm = step == GrantStep.exactAlarm;
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: kInputBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isAlarm
                        ? Icons.alarm_rounded
                        : Icons.battery_charging_full_rounded,
                    color: kBubbleUser,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isAlarm
                          ? 'Let tasks fire on time'
                          : 'Let tasks reach the network',
                      style: const TextStyle(
                        color: kText,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isAlarm
                    ? 'Android needs your permission for exact alarms — otherwise scheduled tasks run late or bunch up.'
                    : 'Battery optimization blocks network for background tasks (especially on mobile data), so runs fail. Allow Unrestricted use for reliable tasks.',
                style: const TextStyle(color: kMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.of(sheetContext).pop(false),
                      child: const Text('Skip'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        if (isAlarm) {
                          await svc.openExactAlarmSettings();
                        } else {
                          await svc.requestBatteryExemption();
                        }
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop(true);
                        }
                      },
                      child: const Text('Allow'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }
}
