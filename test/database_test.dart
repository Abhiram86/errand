import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handy_flutter/services/database.dart';
import 'package:handy_flutter/types/conversation.dart';
import 'package:handy_flutter/types/message.dart';

void main() {
  late HandyDatabase db;

  setUp(() {
    db = HandyDatabase.inMemory();
  });

  tearDown(() async {
    await db.close();
  });

  Conversation makeConversation({
    String? id,
    List<Message> messages = const [],
    List<String> attachments = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? 'conv-1',
      localSystemPrompt: 'system prompt',
      messages: messages,
      currentDir: Directory('/tmp'),
      attachedFileUris: attachments,
      title: 'My chat',
      provider: 'openrouter',
      model: 'some-model',
      createdAt: createdAt ?? DateTime(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime(2026, 1, 2),
    );
  }

  List<Message> sampleMessages() {
    return [
      const UserMessage(id: 'm1', text: 'hello'),
      const AssistantMessage(id: 'm2', text: 'hi there'),
      const ToolMessage(
        id: 'm3',
        text: 'tool output',
        tool: ToolInvocation(name: 'read_file', args: {'path': 'a.txt'}),
        result: 'file contents',
        reasoning: 'because',
        reasoningDetails: [
          {'detail': 'one'},
          {'detail': 'two'},
        ],
      ),
      const ErrorMessage(id: 'm4', text: 'oops', error: 'boom'),
    ];
  }

  test('save + load round-trips a full conversation', () async {
    final conversation = makeConversation(
      messages: sampleMessages(),
      attachments: ['file:///a', 'file:///b'],
    );

    await db.saveConversation(conversation);

    final loaded = await db.loadConversation('conv-1');
    expect(loaded, isNotNull);
    expect(loaded!.id, 'conv-1');
    expect(loaded.localSystemPrompt, 'system prompt');
    expect(loaded.title, 'My chat');
    expect(loaded.provider, 'openrouter');
    expect(loaded.model, 'some-model');
    expect(loaded.currentDir.path, '/tmp');
    expect(loaded.attachedFileUris, ['file:///a', 'file:///b']);
    expect(loaded.createdAt, DateTime(2026, 1, 1));
    expect(loaded.updatedAt, DateTime(2026, 1, 2));

    // Message types and fields survive the round trip.
    expect(loaded.messages, hasLength(4));
    expect(loaded.messages[0], isA<UserMessage>());
    expect(loaded.messages[0].text, 'hello');
    expect(loaded.messages[1], isA<AssistantMessage>());
    expect(loaded.messages[2], isA<ToolMessage>());
    final tool = loaded.messages[2] as ToolMessage;
    expect(tool.tool.name, 'read_file');
    expect(tool.tool.args, {'path': 'a.txt'});
    expect(tool.result, 'file contents');
    expect(tool.reasoning, 'because');
    expect(tool.reasoningDetails, [
      {'detail': 'one'},
      {'detail': 'two'},
    ]);
    expect(loaded.messages[3], isA<ErrorMessage>());
    expect((loaded.messages[3] as ErrorMessage).error, 'boom');
  });

  test('insertMessage appends in order', () async {
    await db.saveConversation(
      makeConversation(
        messages: [const UserMessage(id: 'm1', text: 'hello')],
      ),
    );

    await db.insertMessage(
      'conv-1',
      const AssistantMessage(id: 'm2', text: 'bye'),
    );

    final loaded = await db.loadConversation('conv-1');
    expect(loaded!.messages.map((m) => m.id), ['m1', 'm2']);
  });

  test('replaceMessage swaps a message in place', () async {
    await db.saveConversation(
      makeConversation(
        messages: [
          const UserMessage(id: 'm1', text: 'hello'),
          const AssistantMessage(id: 'm2', text: 'first draft'),
          const UserMessage(id: 'm3', text: 'after'),
        ],
      ),
    );

    await db.replaceMessage(
      'conv-1',
      'm2',
      const AssistantMessage(id: 'm2', text: 'final answer'),
    );

    final loaded = await db.loadConversation('conv-1');
    expect(loaded!.messages, hasLength(3));
    expect(loaded.messages[1].text, 'final answer');
    expect(loaded.messages[1].id, 'm2');
    // Order of neighbours preserved.
    expect(loaded.messages[0].id, 'm1');
    expect(loaded.messages[2].id, 'm3');
  });

  test('replaceMessage appends when id is missing', () async {
    await db.saveConversation(
      makeConversation(
        messages: [const UserMessage(id: 'm1', text: 'hello')],
      ),
    );

    await db.replaceMessage(
      'conv-1',
      'zzz',
      const AssistantMessage(id: 'm2', text: 'new'),
    );
    final loaded = await db.loadConversation('conv-1');
    expect(loaded!.messages.map((m) => m.id), ['m1', 'm2']);
  });

  test('deleteMessage removes a single message', () async {
    final conversation = makeConversation(messages: sampleMessages());
    await db.saveConversation(conversation);

    await db.deleteMessage('conv-1', 'm2');

    final loaded = await db.loadConversation('conv-1');
    expect(loaded!.messages.map((m) => m.id), ['m1', 'm3', 'm4']);
  });

  test('pinConversation toggles isPinned', () async {
    // Regression: pinConversation is a raw-SQL single-statement toggle;
    // this guards the column/table names it hardcodes.
    await db.saveConversation(makeConversation());
    expect((await db.loadConversationSummary('conv-1'))!.isPinned, isFalse);

    await db.pinConversation('conv-1');
    expect((await db.loadConversationSummary('conv-1'))!.isPinned, isTrue);

    await db.pinConversation('conv-1');
    expect((await db.loadConversationSummary('conv-1'))!.isPinned, isFalse);

    // Unknown id must be a no-op, not a crash.
    await db.pinConversation('nope');
  });

  test('touchConversation bumps updatedAt', () async {
    await db.saveConversation(makeConversation());
    await db.touchConversation('conv-1');

    final loaded = await db.loadConversation('conv-1');
    expect(loaded!.updatedAt.isAfter(DateTime(2026, 1, 2)), isTrue);
  });

  // test('loadAllConversations sorts by recency', () async {
  //   final old = makeConversation(
  //     id: 'old',
  //     updatedAt: DateTime(2026, 1, 1),
  //     messages: [const UserMessage(id: 'a', text: 'old')],
  //   );
  //   final fresh = makeConversation(
  //     id: 'fresh',
  //     updatedAt: DateTime(2026, 3, 15),
  //     messages: [const UserMessage(id: 'aa', text: 'fresh')],
  //   );
  //   await db.saveConversation(old);
  //   await db.saveConversation(fresh);

  //   final all = await db.loadAllConversations();
  //   expect(all.map((c) => c.id), ['fresh', 'old']);
  // });

  test('watchConversationSummaries emits and updates', () async {
    final emissions = <List<Conversation>>[];
    final sub = db.watchConversationSummaries().listen(emissions.add);

    await db.saveConversation(makeConversation());
    // Let the stream deliver.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    expect(emissions, isNotEmpty);
    // Last emission contains the saved conversation (as a summary).
    final last = emissions.last;
    expect(last, hasLength(1));
    expect(last.first.id, 'conv-1');
    expect(last.first.messages, isEmpty);
  });

  test('deleteConversation removes children too', () async {
    final conversation = makeConversation(
      messages: sampleMessages(),
      attachments: ['file:///a'],
    );
    await db.saveConversation(conversation);

    await db.deleteConversation('conv-1');

    expect(await db.loadConversation('conv-1'), isNull);
    // expect(await db.loadAllConversations(), isEmpty);
  });

  group('OPT-07 pagination', () {
    List<Message> numberedMessages(int count) => [
      for (var i = 0; i < count; i++) ...[
        UserMessage(id: 'u$i', text: 'question $i'),
        AssistantMessage(id: 'a$i', text: 'answer $i'),
      ],
    ];

    test('loadConversation(messageLimit:) returns newest N in order',
        () async {
      await db.saveConversation(
        makeConversation(messages: numberedMessages(30)),
      );

      final loaded = await db.loadConversation('conv-1', messageLimit: 10);
      expect(loaded!.messages, hasLength(10));
      // The NEWEST 10 messages (m50..m59 of 60), in chronological order.
      expect(loaded.messages.first.id, 'u25');
      expect(loaded.messages.last.id, 'a29');
    });

    test('loadOlderMessages pages backwards without overlap', () async {
      await db.saveConversation(
        makeConversation(messages: numberedMessages(30)),
      );

      // First page: newest 10.
      final firstPage = await db.loadConversation('conv-1', messageLimit: 10);
      final oldestLoaded = firstPage!.messages.first;

      final older = await db.loadOlderMessages(
        'conv-1',
        beforeMessageId: oldestLoaded.id,
        limit: 10,
      );
      expect(older, hasLength(10));
      expect(older.first.id, 'u20');
      expect(older.last.id, 'a24');

      // No dup, no gap against the first page.
      final firstIds = firstPage.messages.map((m) => m.id).toSet();
      expect(
        older.any((m) => firstIds.contains(m.id)),
        isFalse,
      );

      final rest = await db.loadOlderMessages(
        'conv-1',
        beforeMessageId: older.first.id,
        limit: 100,
      );
      expect(rest, hasLength(40));
      expect(rest.first.id, 'u0');
    });

    test('loadOlderMessages returns empty for unknown anchor', () async {
      await db.saveConversation(
        makeConversation(messages: numberedMessages(5)),
      );
      final older = await db.loadOlderMessages(
        'conv-1',
        beforeMessageId: 'nope',
        limit: 10,
      );
      expect(older, isEmpty);
    });

    test('loadOlderConversations pages backwards by (updatedAt, id) cursor',
        () async {
      for (var i = 0; i < 7; i++) {
        await db.saveConversation(
          makeConversation(
            id: 'conv-$i',
            updatedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
          ),
        );
      }

      // Page past everything (cursor newer than all rows).
      final page1 = await db.loadOlderConversations(
        beforeUpdatedAt: DateTime(2026, 1, 8),
        beforeId: 'zzz',
        limit: 3,
      );
      expect(page1.map((c) => c.id), ['conv-6', 'conv-5', 'conv-4']);

      final oldest = page1.last;
      final page2 = await db.loadOlderConversations(
        beforeUpdatedAt: oldest.updatedAt,
        beforeId: oldest.id!,
        limit: 3,
      );
      expect(page2.map((c) => c.id), ['conv-3', 'conv-2', 'conv-1']);

      final oldest2 = page2.last;
      final page3 = await db.loadOlderConversations(
        beforeUpdatedAt: oldest2.updatedAt,
        beforeId: oldest2.id!,
        limit: 3,
      );
      expect(page3.map((c) => c.id), ['conv-0']);
    });

    test('loadOlderConversations breaks updatedAt ties by id', () async {
      // Five conversations sharing one updatedAt — ordering must still be
      // total so cursor pages line up with the watched first page.
      for (var i = 0; i < 5; i++) {
        await db.saveConversation(
          makeConversation(
            id: 'conv-$i',
            updatedAt: DateTime(2026, 1, 1),
          ),
        );
      }

      final page1 = await db.loadOlderConversations(
        beforeUpdatedAt: DateTime(2026, 1, 2),
        beforeId: 'zzz',
        limit: 3,
      );
      expect(page1.map((c) => c.id), ['conv-4', 'conv-3', 'conv-2']);

      final page2 = await db.loadOlderConversations(
        beforeUpdatedAt: page1.last.updatedAt,
        beforeId: page1.last.id!,
        limit: 3,
      );
      expect(page2.map((c) => c.id), ['conv-1', 'conv-0']);
    });

    test('loadConversationSummary returns row without messages', () async {
      await db.saveConversation(
        makeConversation(messages: sampleMessages()),
      );
      final summary = await db.loadConversationSummary('conv-1');
      expect(summary, isNotNull);
      expect(summary!.messages, isEmpty);
      expect(await db.loadConversationSummary('nope'), isNull);
    });

    test('saveConversation is idempotent when called twice', () async {
      // Regression: overlapping saves used to duplicate message rows
      // because the merge was not transactional and messageId had no
      // unique constraint.
      final conversation = makeConversation(messages: sampleMessages());
      await db.saveConversation(conversation);
      await db.saveConversation(conversation);

      final loaded = await db.loadConversation('conv-1');
      expect(loaded!.messages.map((m) => m.id).toSet().length,
          loaded.messages.length);
      expect(loaded.messages, hasLength(4));
    });

    test('watchConversationSummaries respects limit', () async {
      for (var i = 0; i < 5; i++) {
        await db.saveConversation(
          makeConversation(id: 'conv-$i', updatedAt: DateTime(2026, 1, i + 1)),
        );
      }
      final emissions = <List<Conversation>>[];
      final sub = db
          .watchConversationSummaries(limit: 2)
          .listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(emissions.last.map((c) => c.id), ['conv-4', 'conv-3']);
    });

    test(
      'saveConversation merges: rows outside the loaded window survive',
      () async {
        // Persist a 20-message conversation...
        await db.saveConversation(
          makeConversation(messages: numberedMessages(10)),
        );

        // ...then simulate an app restart that only loads the newest 6
        // messages, followed by a save of that window.
        final windowed = await db.loadConversation('conv-1', messageLimit: 6);
        await db.saveConversation(windowed!);

        final reloaded = await db.loadConversation('conv-1');
        expect(reloaded!.messages, hasLength(20));
        expect(reloaded.messages.first.id, 'u0');
        expect(reloaded.messages.last.id, 'a9');

        // Updates inside the window still land.
        final updated = Conversation(
          id: windowed.id,
          localSystemPrompt: windowed.localSystemPrompt,
          messages: [
            for (final m in windowed.messages)
              m.id == 'a9'
                  ? AssistantMessage(id: 'a9', text: 'edited answer')
                  : m,
          ],
          currentDir: windowed.currentDir,
          attachedFileUris: windowed.attachedFileUris,
          title: windowed.title,
          createdAt: windowed.createdAt,
          updatedAt: windowed.updatedAt,
        );
        await db.saveConversation(updated);

        final afterEdit = await db.loadConversation('conv-1');
        expect(afterEdit!.messages, hasLength(20));
        expect(
          afterEdit.messages.last,
          isA<AssistantMessage>().having((m) => m.text, 'text', 'edited answer'),
        );
      },
    );
  });
}
