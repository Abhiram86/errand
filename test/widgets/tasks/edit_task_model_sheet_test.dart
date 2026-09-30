import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/database.dart';
import 'package:errand/widgets/tasks/edit_task_model_sheet.dart';

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

  testWidgets('EditTaskModelSheet renders Task Prompt and updates payloadJson in DB on save',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Insert task with prompt in payloadJson
    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Morning Briefing',
        type: 'recurring',
        status: 'scheduled',
        payloadJson: jsonEncode({
          'prompt': 'Summarize news and weather',
          'model': 'gemini-2.5-flash',
        }),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        repeatAfter: const Value(3600000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditTaskModelSheet(
            task: task,
            db: db,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Title and Prompt labels and values are rendered
    expect(find.text('Task Title'), findsOneWidget);
    expect(find.text('Task Prompt'), findsOneWidget);
    expect(find.text('Morning Briefing'), findsOneWidget);
    expect(find.text('Summarize news and weather'), findsOneWidget);

    // Edit the prompt
    final promptFinder = find.widgetWithText(TextField, 'Summarize news and weather');
    expect(promptFinder, findsOneWidget);
    await tester.enterText(promptFinder, 'Summarize markets and tech news');
    await tester.pumpAndSettle();

    // Tap Save Changes
    final saveButton = find.widgetWithText(ElevatedButton, 'Save Changes');
    expect(saveButton, findsOneWidget);
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify database row was updated with new prompt
    final updatedTask = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    final updatedPayload = jsonDecode(updatedTask.payloadJson) as Map<String, dynamic>;
    expect(updatedPayload['prompt'], 'Summarize markets and tech news');
    expect(updatedPayload['model'], 'gemini-2.5-flash');
  });

  testWidgets('EditTaskModelSheet falls back to task title if prompt is missing in payloadJson',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'System Health Check',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({'model': 'gemini-2.5-flash'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditTaskModelSheet(
            task: task,
            db: db,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Prompt defaults to task title
    expect(find.text('System Health Check'), findsNWidgets(2)); // Once in Title field, once in Prompt field
  });

  testWidgets('EditTaskModelSheet rejects empty prompt with snackbar',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final taskId = await db.into(db.schedulerTasks).insert(
      SchedulerTasksCompanion.insert(
        title: 'Data Backup',
        type: 'one_off',
        status: 'scheduled',
        payloadJson: jsonEncode({'prompt': 'Run backup'}),
        startsAt: now + 60000,
        nextRunAt: Value(now + 60000),
        timezone: 'UTC',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final task = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditTaskModelSheet(
            task: task,
            db: db,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Clear the prompt text
    final promptFinder = find.widgetWithText(TextField, 'Run backup');
    await tester.enterText(promptFinder, '   ');
    await tester.pumpAndSettle();

    // Tap Save Changes
    final saveButton = find.widgetWithText(ElevatedButton, 'Save Changes');
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // Snackbar should warn about empty prompt
    expect(find.text('Task prompt cannot be empty'), findsOneWidget);

    // Database should be unchanged
    final unchangedTask = await (db.select(db.schedulerTasks)..where((t) => t.id.equals(taskId))).getSingle();
    final payload = jsonDecode(unchangedTask.payloadJson) as Map<String, dynamic>;
    expect(payload['prompt'], 'Run backup');
  });
}
