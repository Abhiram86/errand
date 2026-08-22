import 'package:flutter_test/flutter_test.dart';
import 'package:errand/tools/act_tool.dart';

void main() {
  group('looksLikeCommitAction (Draft policy guard)', () {
    test('refuses final-commit controls', () {
      expect(looksLikeCommitAction('Send'), isTrue);
      expect(looksLikeCommitAction('Send message'), isTrue);
      expect(looksLikeCommitAction('Post'), isTrue);
      expect(looksLikeCommitAction('Pay now'), isTrue);
      expect(looksLikeCommitAction('Confirm order'), isTrue);
      expect(looksLikeCommitAction('Delete chat?'), isTrue);
      expect(looksLikeCommitAction('I agree'), isTrue);
      expect(looksLikeCommitAction('Place order'), isTrue,
          reason: '"order" alone is already in the commit list');
    });

    test('allows ordinary navigation and UI controls', () {
      expect(looksLikeCommitAction('Allow'), isFalse);
      expect(looksLikeCommitAction('Next'), isFalse);
      expect(looksLikeCommitAction('Chats'), isFalse);
      expect(looksLikeCommitAction('Settings'), isFalse);
      expect(looksLikeCommitAction('Search'), isFalse);
      expect(looksLikeCommitAction('Dark theme'), isFalse);
      // Word boundary: substring inside another word must NOT match.
      expect(looksLikeCommitAction('Sender address'), isFalse);
      expect(looksLikeCommitAction('Postbox locations'), isFalse);
      expect(looksLikeCommitAction('Confirmed deliveries'), isFalse,
          reason: 'past tense / derived forms are not the commit control');
    });

    test('handles punctuation and casing', () {
      expect(looksLikeCommitAction('SEND!'), isTrue);
      expect(looksLikeCommitAction('  delete  '), isTrue);
      expect(looksLikeCommitAction('Buy now →'), isTrue);
    });
  });
}
