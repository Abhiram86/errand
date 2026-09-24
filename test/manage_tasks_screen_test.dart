import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:errand/screens/manage_tasks_screen.dart';
import 'package:errand/services/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('ManageTasksScreen All Tasks tab search bar filters tasks by title', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Insert 2 tasks with distinct titles
    await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Alpha battery check',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Check battery'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        repeatAfter: const Value(3600000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Beta network audit',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Check network'}),
        startsAt: now + 120000,
        nextRunAt: Value(now + 120000),
        timezone: 'UTC',
        createdAt: now + 1,
        updatedAt: now + 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ManageTasksScreen(database: db, initialTabIndex: 2),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Both tasks should be visible initially on All Tasks tab
    expect(find.text('Alpha battery check'), findsOneWidget);
    expect(find.text('Beta network audit'), findsOneWidget);

    // Enter search text "alpha"
    final searchField = find.byType(TextField);
    expect(searchField, findsOneWidget);

    await tester.enterText(searchField, 'alpha');
    // Wait for 200ms debounce
    await tester.pump(const Duration(milliseconds: 250));

    // Only Alpha should match
    expect(find.text('Alpha battery check'), findsOneWidget);
    expect(find.text('Beta network audit'), findsNothing);

    // Search for a non-existent title
    await tester.enterText(searchField, 'gamma');
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Alpha battery check'), findsNothing);
    expect(find.text('Beta network audit'), findsNothing);
    expect(find.text('No tasks match "gamma".'), findsOneWidget);

    // Clear search using clear button
    final clearButton = find.byIcon(Icons.clear_rounded);
    expect(clearButton, findsOneWidget);
    await tester.tap(clearButton);
    await tester.pump(const Duration(milliseconds: 250));

    // Both tasks visible again
    expect(find.text('Alpha battery check'), findsOneWidget);
    expect(find.text('Beta network audit'), findsOneWidget);

    // Clean up timers
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('ManageTasksScreen AppBar menu contains Pause all and Resume all actions', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Active Task',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Test'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        repeatAfter: const Value(3600000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ManageTasksScreen(database: db, initialTabIndex: 0),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Find and tap popup menu button
    final moreButton = find.byIcon(Icons.more_vert_rounded);
    expect(moreButton, findsOneWidget);

    await tester.tap(moreButton);
    await tester.pumpAndSettle();

    expect(find.text('Pause all schedules (1)'), findsOneWidget);
    expect(find.text('Resume all schedules (0)'), findsOneWidget);

    // Clean up
    await tester.tapAt(const Offset(10, 10)); // Dismiss popup
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('ManageTasksScreen Logs tab displays status indicator badges and supports status filtering', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Network Sync Task',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Sync'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        repeatAfter: const Value(3600000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Insert 1 successful unread log and 1 failed unread log
    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 5000,
        startedAt: Value(now - 4000),
        finishedAt: Value(now - 1000),
        status: 'success',
        noAttempts: const Value(1),
        summary: const Value('Synced 10 items cleanly.'),
        notificationSeen: const Value(0),
        notificationSent: const Value(1),
        createdAt: now - 5000,
        updatedAt: now - 1000,
      ),
    );

    await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now - 10000,
        startedAt: Value(now - 9000),
        finishedAt: Value(now - 8000),
        status: 'failed',
        noAttempts: const Value(1),
        errorMessage: const Value('Connection timed out.'),
        notificationSeen: const Value(0),
        notificationSent: const Value(1),
        createdAt: now - 10000,
        updatedAt: now - 8000,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ManageTasksScreen(database: db, initialTabIndex: 1), // Logs tab
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Both logs should show their status badges
    expect(find.text('SUCCESS'), findsOneWidget);
    expect(find.text('FAILED'), findsOneWidget);

    // Verify filter chips exist: Unread (2), All logs (2), Failed (1), Success (1)
    expect(find.text('Unread (2)'), findsOneWidget);
    expect(find.text('All logs (2)'), findsOneWidget);
    expect(find.text('Failed (1)'), findsOneWidget);
    expect(find.text('Success (1)'), findsOneWidget);

    // Tap Failed filter chip
    await tester.tap(find.text('Failed (1)'));
    await tester.pump(const Duration(milliseconds: 100));

    // Only FAILED log visible
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.text('SUCCESS'), findsNothing);
    expect(find.text('Error: Connection timed out.'), findsOneWidget);

    // Tap Success filter chip
    await tester.tap(find.text('Success (1)'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('SUCCESS'), findsOneWidget);
    expect(find.text('FAILED'), findsNothing);
    expect(find.text('Synced 10 items cleanly.'), findsOneWidget);

    // Clean up
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('ManageTasksScreen Upcoming tab shows focused countdown badge for near-term scheduled task', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Imminent Task',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Check status'}),
        startsAt: now + 45000,
        nextRunAt: Value(now + 45000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ManageTasksScreen(database: db, initialTabIndex: 0),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Imminent Task'), findsOneWidget);
    expect(find.textContaining('Fires in '), findsOneWidget);

    // Clean up
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  test('bounded log window caps rows while COUNT stays exact (P12.3)', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Log flood task',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: '{}',
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    // 30 unread logs: well under the 400 window, but exercises the same
    // pattern — limited watch for rows, COUNT(*) for the badge.
    for (var i = 0; i < 30; i++) {
      await db.into(db.schedulerTaskLogs).insert(
        SchedulerTaskLogsCompanion.insert(
          schedulerTaskId: taskId,
          scheduledFor: now - i * 1000,
          status: 'success',
          notificationSeen: const Value(0),
          notificationSent: const Value(1),
          createdAt: now - i * 1000,
          updatedAt: now - i * 1000,
        ),
      );
    }

    final windowed = await (db.select(db.schedulerTaskLogs)
          ..orderBy([(l) => OrderingTerm.desc(l.createdAt)])
          ..limit(25))
        .get();
    expect(windowed, hasLength(25));

    final countRow = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM scheduler_task_log WHERE notification_seen = 0 AND notification_sent = 1 AND status != 'running'",
          readsFrom: {db.schedulerTaskLogs},
        )
        .getSingle();
    expect(countRow.read<int>('c'), equals(30));
  });
}
