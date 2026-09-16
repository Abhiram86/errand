import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/conversation.dart';
import 'package:errand/widgets/chat_sidebar.dart';

void main() {
  testWidgets('ChatSidebar opens options on both 3-dots tap and row long-press', (tester) async {
    final chat = Conversation(
      id: 'chat-1',
      title: 'Test Conversation',
      messages: const [],
      currentDir: Directory.systemTemp,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    bool renamed = false;
    bool deleted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatSidebar(
            pinnedConversations: const [],
            conversations: [chat],
            activeConversationId: 'chat-1',
            hasMoreConversations: false,
            isLoadingMoreConversations: false,
            onLoadMoreConversations: () {},
            onClose: () {},
            onSelectConversation: (_) {},
            onDeleteConversation: (_) {
              deleted = true;
            },
            optionsBuilder: (c) => [
              ChatOption(
                title: 'Rename',
                icon: Icons.edit,
                onTap: () {
                  renamed = true;
                },
              ),
              ChatOption(
                title: 'Delete',
                icon: Icons.delete,
                onTap: () {
                  deleted = true;
                },
              ),
            ],
          ),
        ),
      ),
    );

    // 1. Verify long-pressing the row opens the bottom sheet options
    await tester.longPress(find.text('Test Conversation'));
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Tap Rename and dismiss
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(renamed, isTrue);

    // 2. Verify tapping 3-dots also opens the options
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
