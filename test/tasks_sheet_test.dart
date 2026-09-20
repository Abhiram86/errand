import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/database.dart';
import 'package:errand/widgets/tasks_sheet.dart';

void main() {
  late ErrandDatabase db;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = ErrandDatabase.inMemory();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('task_scheduler'), (call) async => true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('task_scheduler'), null);
    await db.close();
  });

  testWidgets('TasksSheet renders empty state and allows adding test task', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TasksSheet(database: db),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Scheduled Tasks'), findsOneWidget);
    expect(find.text('No scheduled tasks yet'), findsOneWidget);
    expect(find.text('+ Test (10s)'), findsOneWidget);

    // Tap + Test (10s) to insert test task into database
    await tester.tap(find.text('+ Test (10s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify task is now visible in the sheet
    expect(find.text('Test alarm task'), findsOneWidget);
    expect(find.text('SCHEDULED'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    // Clear snackbar and settle
    ScaffoldMessenger.of(tester.element(find.byType(TasksSheet))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('TasksSheet renders existing task with status and actions', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Battery check task',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Check battery'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        repeatAfter: const Value(3600000),
        totalRuns: const Value(3),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Insert 3 execution logs: 2 successes and 1 failed
    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 7200000,
        status: 'success',
        createdAt: now - 7200000,
        updatedAt: now - 7200000,
      ),
    );
    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 3600000,
        status: 'failed',
        createdAt: now - 3600000,
        updatedAt: now - 3600000,
      ),
    );
    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now,
        status: 'success',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TasksSheet(database: db),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Battery check task'), findsOneWidget);
    expect(find.text('SCHEDULED'), findsOneWidget);
    expect(find.text('RECURRING'), findsOneWidget);
    expect(find.textContaining('repeats every 60m'), findsOneWidget);
    expect(find.text('Runs: 3 • Success: 2 • Fails: 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('TasksSheet surfaces exact alarm denial banner when not permitted', (tester) async {
    var openedSettings = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('task_scheduler'), (call) async {
      if (call.method == 'canScheduleExactAlarms') return false;
      if (call.method == 'openExactAlarmSettings') {
        openedSettings = true;
        return true;
      }
      return true;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TasksSheet(database: db),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Exact alarms not permitted'), findsOneWidget);
    expect(find.text('Enable'), findsOneWidget);

    await tester.tap(find.text('Enable'));
    await tester.pump();

    expect(openedSettings, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
