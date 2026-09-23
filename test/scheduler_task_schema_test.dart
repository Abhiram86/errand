import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/database.dart';

void main() {
  late ErrandDatabase db;

  setUp(() {
    db = ErrandDatabase.inMemory();
  });

  tearDown(() async {
    await db.close();
  });

  test('ErrandDatabase schemaVersion is 8', () {
    expect(db.schemaVersion, equals(8));
  });

  test('scheduler_task and scheduler_task_log table insertion and cascade delete', () async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Insert into scheduler_task
    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Battery and storage check',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: '{"prompt": "Check battery and storage", "model": "test-model"}',
        startsAt: now,
        timezone: 'Asia/Kolkata',
        createdAt: now,
        updatedAt: now,
        nextRunAt: Value(now + 3600000),
        repeatAfter: const Value(3600000),
      ),
    );

    expect(taskId, isPositive);

    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    expect(task.title, equals('Battery and storage check'));
    expect(task.type, equals('recurring'));
    expect(task.status, equals('scheduled'));
    expect(task.repeatAfter, equals(3600000));
    expect(task.retriesPerTurn, equals(3));
    expect(task.failures, equals(0));
    expect(task.totalRuns, equals(0));

    // 2. Insert into scheduler_task_log
    final logId = await db.into(db.schedulerTaskLogs).insert(
      SchedulerTaskLogsCompanion.insert(
        schedulerTaskId: taskId,
        scheduledFor: now,
        status: 'success',
        createdAt: now,
        updatedAt: now,
        startedAt: Value(now + 100),
        finishedAt: Value(now + 2000),
        outputFilePath: const Value('/path/to/report.md'),
        summary: const Value('Battery is 85%, storage has 45GB free'),
        notificationSent: const Value(1),
        notificationSeen: const Value(0),
      ),
    );

    expect(logId, isPositive);

    final log = await (db.select(db.schedulerTaskLogs)..where((l) => l.id.equals(logId))).getSingle();
    expect(log.schedulerTaskId, equals(taskId));
    expect(log.status, equals('success'));
    expect(log.outputFilePath, equals('/path/to/report.md'));
    expect(log.summary, contains('Battery is 85%'));
    expect(log.notificationSent, equals(1));
    expect(log.notificationSeen, equals(0));

    // 3. Cascade deletion: deleting task removes its logs
    await (db.delete(db.schedulerTasks)..where((t) => t.id.equals(taskId))).go();
    final remainingLogs = await (db.select(db.schedulerTaskLogs)..where((l) => l.schedulerTaskId.equals(taskId))).get();
    expect(remainingLogs, isEmpty);
  });
}
