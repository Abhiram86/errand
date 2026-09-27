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

  /// Mutex to prevent burst task creations (e.g. batch/agent tasks) from
  /// pushing overlapping modal sheets.
  static bool _isPrompting = false;

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

  /// Returns true if [errorMessage] or [isTimeout] indicates a Doze-suspected failure
  /// (e.g. timeouts, unreachable host, broken socket, network restricted).
  static bool isDozeSuspectedFailure(String? errorMessage, {bool isTimeout = false}) {
    if (isTimeout) return true;
    if (errorMessage == null || errorMessage.isEmpty) return false;
    final msg = errorMessage.toLowerCase();
    return msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('unknownhost') ||
        msg.contains('failed host lookup') ||
        msg.contains('socket') ||
        msg.contains('connection lost') ||
        msg.contains('connection reset') ||
        msg.contains('network is unreachable') ||
        msg.contains('no route to host') ||
        // Broad signature: captures LLM-side connection drops under Doze packet freezes.
        msg.contains('client closed');
  }

  /// When a background task fails with a Doze-suspected signature (e.g. timeout /
  /// network block under Doze / UnknownHost), reset the prompted flags so the
  /// creation or recovery flow can re-prompt in the UI. Unrelated failures
  /// (e.g. model errors, schema validation) preserve the once-per-grant cooldown.
  ///
  /// Calling without [errorMessage] or [isTimeout] acts as an explicit caller override
  /// to unconditionally clear the cooldown flags (used for manual resets and in tests).
  static Future<void> rearmOnFailure(
    ErrandDatabase db, {
    String? errorMessage,
    bool isTimeout = false,
  }) async {
    if (errorMessage != null || isTimeout) {
      if (!isDozeSuspectedFailure(errorMessage, isTimeout: isTimeout)) {
        return;
      }
    }
    try {
      await db.deleteSetting(_kBatteryPrompted);
      await db.deleteSetting(_kExactPrompted);
    } catch (_) {}
  }

  /// Entry point: call (fire-and-forget) when a scheduled task is created.
  /// Checks grant states and shows the next unprompted step as a bottom
  /// sheet. Never throws — failures stay silent, the toast already fired.
  static Future<void> maybePromptAfterTaskCreated(
    BuildContext context, {
    ErrandDatabase? database,
    TaskSchedulerService? scheduler,
  }) async {
    if (_isPrompting) return;
    _isPrompting = true;
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

        // User tapped "Allow" and was redirected to an external OS setting.
        // Wait for the user to return to Errand before evaluating the next step.
        await _waitForAppResume();
        if (!context.mounted) return;

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
    } catch (_) {
    } finally {
      _isPrompting = false;
    }
  }

  /// Waits for the app to resume after the user was sent to external OS settings.
  static Future<void> _waitForAppResume() async {
    final completer = Completer<void>();
    AppLifecycleListener? listener;
    Timer? timeout;

    listener = AppLifecycleListener(
      onResume: () {
        if (!completer.isCompleted) completer.complete();
      },
      onPause: () {
        // App transitioned to background Settings; give user ample time (up to 10m).
        timeout?.cancel();
        timeout = Timer(const Duration(minutes: 10), () {
          if (!completer.isCompleted) completer.complete();
        });
      },
    );

    // Initial fallback: if app never paused within 2.5s (e.g. settings failed to open or on desktop),
    // proceed without blocking.
    timeout = Timer(const Duration(milliseconds: 2500), () {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future;
    } finally {
      timeout?.cancel();
      listener.dispose();
    }

    // Small delay for UI and route transitions to settle on resume.
    await Future<void>.delayed(const Duration(milliseconds: 300));
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
