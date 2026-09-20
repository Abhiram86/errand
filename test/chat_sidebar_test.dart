import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/conversation.dart';
import 'package:errand/widgets/chat_sidebar.dart';

void main() {
  testWidgets(
    'ChatSidebar opens options on both 3-dots tap and row long-press',
    (tester) async {
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
      bool showedNotes = false;
      bool checkedUpdates = false;

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
              onShowReleaseNotes: () => showedNotes = true,
              onCheckForUpdates: () => checkedUpdates = true,
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

      // 3. Verify tapping release notes button triggers callback
      await tester.tap(find.byIcon(Icons.new_releases_outlined));
      await tester.pumpAndSettle();
      expect(showedNotes, isTrue);

      await tester.tap(find.byIcon(Icons.system_update_alt_rounded));
      await tester.pumpAndSettle();
      expect(checkedUpdates, isTrue);
    },
  );

  testWidgets(
    'ChatSidebar displays "Manage tasks" at the top and invokes callback when tapped',
    (tester) async {
      bool managedTasks = false;
      bool closed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatSidebar(
              pinnedConversations: const [],
              conversations: const [],
              activeConversationId: null,
              hasMoreConversations: false,
              isLoadingMoreConversations: false,
              onLoadMoreConversations: () {},
              onClose: () => closed = true,
              onManageTasks: () => managedTasks = true,
              onSelectConversation: (_) {},
              onDeleteConversation: (_) {},
              optionsBuilder: (_) => const [],
            ),
          ),
        ),
      );

      expect(find.text('Manage tasks'), findsOneWidget);
      expect(find.byIcon(Icons.alarm_rounded), findsOneWidget);

      await tester.tap(find.text('Manage tasks'));
      await tester.pumpAndSettle();

      expect(managedTasks, isTrue);
      expect(closed, isTrue);
    },
  );
}
