import 'package:flutter_test/flutter_test.dart';
import 'package:errand/tools/act_tool.dart';

void main() {
  group('looksLikeCommitAction (Draft policy guard)', () {
    test('refuses final-commit controls, returning the matched word', () {
      expect(looksLikeCommitAction('Send'), 'send');
      expect(looksLikeCommitAction('Send message'), 'send');
      expect(looksLikeCommitAction('Post'), 'post');
      expect(looksLikeCommitAction('Pay now'), 'pay');
      expect(looksLikeCommitAction('Confirm order'), 'confirm');
      expect(looksLikeCommitAction('Delete chat?'), 'delete');
      expect(looksLikeCommitAction('I agree'), 'agree');
      expect(looksLikeCommitAction('Place order'), 'order',
          reason: '"order" alone is already in the commit list');
      // Hyphenated compounds match as a whole token when listed ('reply-all')
      // and segment-wise otherwise; the matched pattern is reported either way.
      expect(looksLikeCommitAction('Reply-all'), 'reply-all');
      expect(looksLikeCommitAction('Confirm-order-now'), 'confirm');
    });

    test('allows ordinary navigation and UI controls', () {
      expect(looksLikeCommitAction('Allow'), isNull);
      expect(looksLikeCommitAction('Next'), isNull);
      expect(looksLikeCommitAction('Chats'), isNull);
      expect(looksLikeCommitAction('Settings'), isNull);
      expect(looksLikeCommitAction('Search'), isNull);
      expect(looksLikeCommitAction('Dark theme'), isNull);
      // Word boundary: substring inside another word must NOT match.
      expect(looksLikeCommitAction('Sender address'), isNull);
      expect(looksLikeCommitAction('Postbox locations'), isNull);
      expect(looksLikeCommitAction('Confirmed deliveries'), isNull,
          reason: 'past tense / derived forms are not the commit control');
    });

    test('handles punctuation and casing', () {
      expect(looksLikeCommitAction('SEND!'), 'send');
      expect(looksLikeCommitAction('  delete  '), 'delete');
      expect(looksLikeCommitAction('Buy now →'), 'buy');
    });
  });
}
