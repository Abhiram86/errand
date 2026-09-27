import 'package:errand/services/task_progress_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskProgressService', () {
    late TaskProgressService service;

    setUp(() {
      service = TaskProgressService.instance;
      service.clear(99);
    });

    tearDown(() {
      service.clear(99);
    });

    test('emits, records latest, and keeps history for task', () async {
      final events = <TaskProgressEvent>[];
      final sub = service.stream.listen(events.add);

      service.emit(
        TaskProgressEvent(
          taskId: 99,
          stage: TaskExecutionStage.starting,
          message: 'Task starting',
        ),
      );

      service.emit(
        TaskProgressEvent(
          taskId: 99,
          stage: TaskExecutionStage.thinking,
          turn: 0,
          message: 'Thinking...',
        ),
      );

      service.emit(
        TaskProgressEvent(
          taskId: 99,
          stage: TaskExecutionStage.toolExecuting,
          turn: 0,
          toolName: 'bash',
          toolArgs: {'command': 'ls'},
          message: 'Calling tool: bash',
        ),
      );

      service.emit(
        TaskProgressEvent(
          taskId: 99,
          stage: TaskExecutionStage.toolCompleted,
          turn: 0,
          toolName: 'bash',
          toolResultSnippet: 'file1.txt',
          toolOk: true,
          message: 'bash succeeded',
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(events.length, equals(4));
      expect(service.getLatest(99)?.stage, equals(TaskExecutionStage.toolCompleted));
      expect(service.getLatest(99)?.stageLabel, equals('Tool Finished'));
      expect(service.getHistory(99).length, equals(4));
      expect(service.getHistory(99)[0].stage, equals(TaskExecutionStage.starting));
      expect(service.getHistory(99)[2].toolName, equals('bash'));

      service.clear(99);
      expect(service.getLatest(99), isNull);
      expect(service.getHistory(99), isEmpty);
    });
  });
}
