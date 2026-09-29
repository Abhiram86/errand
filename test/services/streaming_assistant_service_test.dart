import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/streaming_assistant_service.dart';

void main() {
  group('StreamingAssistantService - Tag Healing (healMarkdown)', () {
    test('returns empty string on empty input', () {
      expect(StreamingAssistantService.healMarkdown(''), '');
    });

    test('preserves already-closed markdown without changes', () {
      expect(
        StreamingAssistantService.healMarkdown('This is **bold** text.'),
        'This is **bold** text.',
      );
      expect(
        StreamingAssistantService.healMarkdown('Use `const` for immutability.'),
        'Use `const` for immutability.',
      );
      expect(
        StreamingAssistantService.healMarkdown('Visit [Google](https://google.com).'),
        'Visit [Google](https://google.com).',
      );
      expect(
        StreamingAssistantService.healMarkdown('```dart\nvoid main() {}\n```'),
        '```dart\nvoid main() {}\n```',
      );
    });

    test('heals unclosed bold markers (**)', () {
      expect(
        StreamingAssistantService.healMarkdown('This is **bold text'),
        'This is **bold text**',
      );
    });

    test('heals unclosed italic markers (*)', () {
      expect(
        StreamingAssistantService.healMarkdown('This is *italic text'),
        'This is *italic text*',
      );
    });

    test('heals unclosed bold-italic markers (***)', () {
      expect(
        StreamingAssistantService.healMarkdown('This is ***very bold'),
        'This is ***very bold***',
      );
    });

    test('heals unclosed inline code (`)', () {
      expect(
        StreamingAssistantService.healMarkdown('Use `variableName'),
        'Use `variableName`',
      );
    });

    test('heals unclosed code fence (```)', () {
      expect(
        StreamingAssistantService.healMarkdown('```dart\nvoid main() {'),
        '```dart\nvoid main() {\n```',
      );
      expect(
        StreamingAssistantService.healMarkdown('```dart\nvoid main() {\n'),
        '```dart\nvoid main() {\n```',
      );
    });

    test('heals unclosed tilde fence (~~~)', () {
      expect(
        StreamingAssistantService.healMarkdown('~~~json\n{"key": 1}'),
        '~~~json\n{"key": 1}\n~~~',
      );
    });

    test('heals unclosed strikethrough (~~)', () {
      expect(
        StreamingAssistantService.healMarkdown('This was ~~wrong'),
        'This was ~~wrong~~',
      );
    });

    test(r'heals unclosed math blocks ($$ and $)', () {
      expect(
        StreamingAssistantService.healMarkdown('Formula: \$\$x = 1'),
        'Formula: \$\$x = 1\$\$',
      );
      expect(
        StreamingAssistantService.healMarkdown('Value: \$5'),
        'Value: \$5\$',
      );
    });

    test('heals unclosed links ([text](url)', () {
      expect(
        StreamingAssistantService.healMarkdown('See [documentation](https://docs'),
        'See [documentation](https://docs)',
      );
      expect(
        StreamingAssistantService.healMarkdown('See [documentation'),
        'See [documentation]',
      );
    });

    test('preserves bullet lists with asterisks without misidentifying as italic', () {
      const listText = '* Item one\n* Item two\n* Item three';
      expect(
        StreamingAssistantService.healMarkdown(listText),
        listText,
      );
    });

    test('heals nested unclosed tags in correct reverse order', () {
      expect(
        StreamingAssistantService.healMarkdown('Here is **bold and *italic'),
        'Here is **bold and *italic***',
      );
    });
  });

  group('StreamingAssistantService - Status & Transitions', () {
    test('initial state is working with placeholder label', () {
      final service = StreamingAssistantService();
      expect(service.status, StreamingAssistantStatus.working);
      expect(service.placeholderLabel, '…working');
      expect(service.hasContent, false);
      expect(service.currentPristineText, '');
    });

    test('startReasoning flips status to thinking and updates placeholder', () {
      StreamingSnapshot? latestSnapshot;
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => latestSnapshot = snapshot,
      );

      service.startReasoning();
      expect(service.status, StreamingAssistantStatus.thinking);
      expect(service.placeholderLabel, '…thinking');
      expect(latestSnapshot?.status, StreamingAssistantStatus.thinking);
      expect(latestSnapshot?.placeholderLabel, '…thinking');
    });

    test('setCompacting toggles compacting label and status', () {
      StreamingSnapshot? latestSnapshot;
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => latestSnapshot = snapshot,
      );

      service.setCompacting(true);
      expect(service.status, StreamingAssistantStatus.compacting);
      expect(service.placeholderLabel, '…compacting context');
      expect(latestSnapshot?.placeholderLabel, '…compacting context');

      service.setCompacting(false);
      expect(service.status, StreamingAssistantStatus.working);
      expect(service.placeholderLabel, '…working');
    });

    test('setRetry updates retrying label with attempt number', () {
      StreamingSnapshot? latestSnapshot;
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => latestSnapshot = snapshot,
      );

      service.setRetry(2);
      expect(service.status, StreamingAssistantStatus.retrying);
      expect(service.placeholderLabel, '…retrying · attempt 2');
      expect(latestSnapshot?.placeholderLabel, '…retrying · attempt 2');
    });

    test('appendDelta clears retry label and switches to streaming', () {
      StreamingSnapshot? latestSnapshot;
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => latestSnapshot = snapshot,
      );

      service.setRetry(1);
      service.appendDelta('First token');
      service.flushNow();

      expect(service.status, StreamingAssistantStatus.streaming);
      expect(service.retryAttempt, isNull);
      expect(service.hasContent, true);
      expect(service.currentPristineText, 'First token');
      expect(latestSnapshot?.status, StreamingAssistantStatus.streaming);
    });
  });

  group('StreamingAssistantService - Paragraph & Block Segmentation', () {
    test('segments paragraphs on double newlines and flushes immediately', () {
      final snapshots = <StreamingSnapshot>[];
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => snapshots.add(snapshot),
      );

      service.appendDelta('Paragraph 1 line 1.\n');
      service.appendDelta('Paragraph 1 line 2.\n\n'); // Boundary triggers instant flush

      expect(snapshots.isNotEmpty, true);
      final last = snapshots.last;
      expect(last.finalizedBlocks.length, 1);
      expect(last.finalizedBlocks[0], 'Paragraph 1 line 1.\nParagraph 1 line 2.');
      expect(last.activeTail, '');

      // Stream into paragraph 2
      service.appendDelta('Paragraph 2 starts here');
      service.flushNow();

      final updated = snapshots.last;
      expect(updated.finalizedBlocks.length, 1);
      expect(updated.activeTail, 'Paragraph 2 starts here');
      expect(updated.displayBlocks.length, 2);
      expect(updated.displayBlocks[1], 'Paragraph 2 starts here');
    });

    test('does not split code fences on internal double newlines', () {
      final snapshots = <StreamingSnapshot>[];
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => snapshots.add(snapshot),
      );

      service.appendDelta('```dart\nvoid main() {\n\n  print("hello");\n}\n```\n');

      expect(snapshots.isNotEmpty, true);
      final last = snapshots.last;
      expect(last.finalizedBlocks.length, 1);
      expect(
        last.finalizedBlocks[0],
        '```dart\nvoid main() {\n\n  print("hello");\n}\n```',
      );
    });

    test('heals active tail markdown during streaming', () {
      final snapshots = <StreamingSnapshot>[];
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => snapshots.add(snapshot),
      );

      service.appendDelta('Here is **important');
      service.flushNow();

      final snapshot = snapshots.last;
      expect(snapshot.activeTail, 'Here is **important');
      expect(snapshot.healedTail, 'Here is **important**');
      expect(snapshot.fullDisplayText, 'Here is **important**');
    });

    test('finalize moves remaining tail to finalizedBlocks and returns clean text', () {
      final service = StreamingAssistantService();
      service.appendDelta('Paragraph 1.\n\nParagraph 2.');

      final result = service.finalize();
      expect(result, 'Paragraph 1.\n\nParagraph 2.');

      // Service state is properly closed
      expect(service.currentPristineText, 'Paragraph 1.\n\nParagraph 2.');
    });

    test('finalizeStopped formats partial text with stopped marker', () {
      final service = StreamingAssistantService();
      service.appendDelta('Partial response before stop');

      final result = service.finalizeStopped();
      expect(result, 'Partial response before stop\n\n_(stopped)_');
    });

    test('finalizeStopped returns empty string if nothing streamed', () {
      final service = StreamingAssistantService();
      final result = service.finalizeStopped();
      expect(result, '');
    });

    test('reset clears all buffers and restores working status', () {
      final service = StreamingAssistantService();
      service.appendDelta('Some text\n\nMore text');
      expect(service.hasContent, true);

      service.reset();
      expect(service.hasContent, false);
      expect(service.currentPristineText, '');
      expect(service.status, StreamingAssistantStatus.working);
      expect(service.placeholderLabel, '…working');
    });

    testWidgets('fallback flush fires after 1200ms when no paragraph boundary arrives', (tester) async {
      final snapshots = <StreamingSnapshot>[];
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => snapshots.add(snapshot),
      );

      service.appendDelta('Long sentence without paragraph break');

      // Before fallback interval: no snapshot emitted
      await tester.pump(const Duration(milliseconds: 600));
      expect(snapshots.isEmpty, true);

      // After 1200ms fallback interval: snapshot emitted
      await tester.pump(const Duration(milliseconds: 700));
      expect(snapshots.isNotEmpty, true);
      expect(snapshots.last.fullDisplayText, 'Long sentence without paragraph break');

      service.dispose();
    });

    testWidgets('table row in progress holds flush until tableHoldInterval', (tester) async {
      final snapshots = <StreamingSnapshot>[];
      final service = StreamingAssistantService(
        onUpdate: (snapshot) => snapshots.add(snapshot),
      );

      service.appendDelta('| Col 1 | Col 2 |');

      // Before table hold interval (250ms)
      await tester.pump(const Duration(milliseconds: 100));
      expect(snapshots.isEmpty, true);

      // After table hold interval (250ms)
      await tester.pump(const Duration(milliseconds: 200));
      expect(snapshots.isNotEmpty, true);
      expect(snapshots.last.fullDisplayText, '| Col 1 | Col 2 |');

      service.dispose();
    });
  });
}
