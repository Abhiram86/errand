import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
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

  group('actTool then_read integration', () {
    test('appends screen outline when then_read is true and action succeeds', () async {
      final mock = MockA11yService();
      final tool = actTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'call_1',
          name: 'act',
          arguments: {'action': 'tap', 'ref': 1, 'then_read': true},
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Tapped [1]'));
      expect(res.output, contains('[Screen after action]:'));
      expect(res.output, contains('Screen: package=com.example'));
    });

    test('omits screen outline when then_read is false', () async {
      final mock = MockA11yService();
      final tool = actTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'call_2',
          name: 'act',
          arguments: {'action': 'tap', 'ref': 1, 'then_read': false},
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Tapped [1]'));
      expect(res.output, isNot(contains('[Screen after action]:')));
    });

    test('handles unchanged screen gracefully when then_read is true', () async {
      final mock = MockA11yService()..unchanged = true;
      final tool = actTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'call_3',
          name: 'act',
          arguments: {'action': 'tap', 'ref': 1, 'then_read': true},
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Tapped [1]'));
      expect(res.output, contains('[Screen after action]: UNCHANGED'));
    });

    test('throws A11yRequiredException if accessibility is disabled', () async {
      final mock = MockA11yService()..enabled = false;
      final tool = actTool(service: mock);
      final call = const ToolCall(
        id: 'call_disabled',
        name: 'act',
        arguments: {'action': 'tap', 'ref': 1},
      );
      expect(() => tool.handler(call), throwsA(isA<A11yRequiredException>()));
    });
  });
}

class MockA11yService extends A11yService {
  bool enabled = true;
  bool tapSuccess = true;
  String screenOutline = 'Screen: package=com.example\n[1] Button "Next"';
  bool unchanged = false;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> isRestricted() async => false;

  @override
  Future<Map<String, dynamic>> tapByRef(int ref, {bool longClick = false}) async {
    if (!tapSuccess) return {'ok': false, 'message': 'Ref tap failed'};
    return {'ok': true, 'message': 'Tapped [$ref]'};
  }

  @override
  Future<Map<String, dynamic>> tapByText(
    String label, {
    bool exact = false,
    int occurrence = 1,
  }) async {
    if (!tapSuccess) return {'ok': false, 'message': 'Text tap failed'};
    return {'ok': true, 'label': label, 'message': 'Tapped "$label"'};
  }

  @override
  Future<Map<String, dynamic>> probeChanged({int settleMs = 600}) async {
    return {'ok': true, 'changed': true};
  }

  @override
  Future<Map<String, dynamic>> readScreen({
    int maxNodes = 300,
    bool full = false,
    bool probe = false,
  }) async {
    if (unchanged) {
      return {'ok': true, 'unchanged': true};
    }
    return {
      'ok': true,
      'outline': screenOutline,
    };
  }
}
