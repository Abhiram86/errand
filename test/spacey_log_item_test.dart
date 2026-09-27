import 'package:errand/services/database.dart';
import 'package:errand/services/task_progress_service.dart';
import 'package:errand/widgets/tasks/spacey_log_item.dart';
import 'package:errand/widgets/tasks/spacey_task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SpaceyLogItem suppresses dropdown chevron when linkedFiles is empty', (tester) async {
    final log = SchedulerTaskLogRow(
      id: 1,
      schedulerTaskId: 10,
      scheduledFor: 1000,
      status: 'success',
      summary: 'Completed without linked files',
      outputFilePath: 'task-10-output.md',
      linkedFiles: '[]',
      notificationSent: 1,
      notificationSeen: 1,
      noAttempts: 1,
      createdAt: 1000,
      updatedAt: 1000,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpaceyLogItem(
            log: log,
            task: null,
            onMarkSeen: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
  });

  testWidgets('SpaceyLogItem shows dropdown chevron when linkedFiles has files', (tester) async {
    final log = SchedulerTaskLogRow(
      id: 2,
      schedulerTaskId: 10,
      scheduledFor: 1000,
      status: 'success',
      summary: 'Completed with linked files',
      outputFilePath: 'task-10-output.md',
      linkedFiles: '["page1.html", "page2.html"]',
      notificationSent: 1,
      notificationSeen: 1,
      noAttempts: 1,
      createdAt: 1000,
      updatedAt: 1000,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpaceyLogItem(
            log: log,
            task: null,
            onMarkSeen: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    // Tap to expand
    await tester.tap(find.byType(SpaceyLogItem));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);
    expect(find.text('Linked Files (2)'), findsOneWidget);
  });

  testWidgets('SpaceyTaskRow shows live debug trace and copy trace button when running', (tester) async {
    final db = ErrandDatabase.inMemory();
    addTearDown(() => db.close());

    TaskProgressService.instance.clear(5);
    addTearDown(() => TaskProgressService.instance.clear(5));

    TaskProgressService.instance.emit(
      TaskProgressEvent(
        taskId: 5,
        stage: TaskExecutionStage.toolExecuting,
        turn: 0,
        toolName: 'bash',
        toolArgs: {'command': 'cat hello.txt'},
        message: 'Calling tool: bash',
      ),
    );

    final task = SchedulerTaskRow(
      id: 5,
      title: 'Active Debug Task',
      type: 'one_off',
      status: 'running',
      payloadJson: '{}',
      startsAt: 1000,
      timezone: 'UTC',
      notify: true,
      totalRuns: 1,
      failures: 0,
      retriesPerTurn: 3,
      createdAt: 1000,
      updatedAt: 1000,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpaceyTaskRow(
            task: task,
            logs: const [],
            db: db,
            onViewLogs: () {},
          ),
        ),
      ),
    );

    expect(find.text('DEBUG LIVE WATCH'), findsOneWidget);
    expect(find.text('Calling tool: bash'), findsOneWidget);
    expect(find.text('Copy Trace'), findsOneWidget);

    // Tap copy trace
    await tester.tap(find.text('Copy Trace'));
    await tester.pump();

    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
