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

    test('handles punctuation, casing, and hyphenated compounds', () {
      expect(looksLikeCommitAction('SEND!'), 'send');
      expect(looksLikeCommitAction('  delete  '), 'delete');
      expect(looksLikeCommitAction('Buy now →'), 'buy');
      expect(looksLikeCommitAction('confirm-order'), 'confirm');
      expect(looksLikeCommitAction('order-confirmation'), 'order');
      expect(looksLikeCommitAction('reply-all'), 'reply-all');
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

    test('filters screen outline with grep when then_read is true and shows tap info', () async {
      final mock = MockA11yService()
        ..screenOutline =
            'Screen: package=com.example\n[1] Button "Next"\n[2] Switch "Dark theme"';
      final tool = actTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'call_grep',
          name: 'act',
          arguments: {
            'action': 'tap',
            'ref': 1,
            'then_read': true,
            'grep': 'Dark',
          },
        ),
      );

      expect(res.ok, isTrue);
      // Tap information is always preserved at the top
      expect(res.output, contains('Tapped [1]'));
      expect(res.output, contains('[Screen after action (grep: "Dark")]:'));
      expect(res.output, contains('Screen: package=com.example'));
      expect(res.output, contains('[2] Switch "Dark theme"'));
      expect(res.output, isNot(contains('[1] Button "Next"')));
    });

    test('passing grep automatically reads and returns tap info with matches', () async {
      final mock = MockA11yService()
        ..screenOutline =
            'Screen: package=com.example\n[1] Button "Next"\n[2] Switch "Dark theme"';
      final tool = actTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'call_grep_implicit',
          name: 'act',
          arguments: {
            'action': 'tap',
            'ref': 1,
            'grep': 'Dark',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Tapped [1]'));
      expect(res.output, contains('[Screen after action (grep: "Dark")]:'));
      expect(res.output, contains('[2] Switch "Dark theme"'));
      expect(res.output, isNot(contains('[1] Button "Next"')));
    });
  });

  group('C2: Numeric-ref commit guard & modal post-hook', () {
    test('ref tap on a Pay/Delete/Send-labeled node is refused with the exact same error as the label path', () async {
      final mock = MockA11yService()
        ..screenOutline = 'Screen: package=com.example\n'
            '[1] Button "Pay now"\n'
            '[2] Button "Delete chat?"\n'
            '[3] Button "Send message"\n'
            '[4] Button "Next"';
      final tool = actTool(service: mock);

      // Populate ref cache by reading screen
      await mock.readScreen();

      for (final (ref, label, word) in [
        (1, 'Pay now', 'pay'),
        (2, 'Delete chat?', 'delete'),
        (3, 'Send message', 'send'),
      ]) {
        final labelRes = await tool.handler(
          ToolCall(
            id: 'call_label_$ref',
            name: 'act',
            arguments: {'action': 'tap', 'label': label},
          ),
        );
        final refRes = await tool.handler(
          ToolCall(
            id: 'call_ref_$ref',
            name: 'act',
            arguments: {'action': 'tap', 'ref': ref},
          ),
        );

        expect(labelRes.ok, isFalse);
        expect(refRes.ok, isFalse);
        expect(refRes.error?.message, equals(labelRes.error?.message));
        expect(refRes.error?.message, equals(formatCommitRefusal(label, word)));
      }

      // Safe control succeeds
      final nextRes = await tool.handler(
        const ToolCall(
          id: 'call_next',
          name: 'act',
          arguments: {'action': 'tap', 'ref': 4},
        ),
      );
      expect(nextRes.ok, isTrue);
      expect(nextRes.output, contains('Tapped [4]'));
    });

    test('long_press by ref also enforces commit guard with identical error', () async {
      final mock = MockA11yService()
        ..screenOutline = 'Screen: package=com.example\n[1] Button "Delete chat"';
      final tool = actTool(service: mock);
      await mock.readScreen();

      final res = await tool.handler(
        const ToolCall(
          id: 'call_lp',
          name: 'act',
          arguments: {'action': 'long_press', 'ref': 1},
        ),
      );

      expect(res.ok, isFalse);
      expect(res.error?.message, equals(formatCommitRefusal('Delete chat', 'delete')));
    });

    test('modal post-hook pauses the agent loop if a confirmation dialog appears post-tap', () async {
      final mock = MockA11yService()
        ..screenOutline = 'Screen: package=com.example\n[1] Button "Proceed"'
        ..modalOnProbe = 'AlertDialog: "Confirm transaction of \$50?"';
      final tool = actTool(service: mock);
      await mock.readScreen();

      final res = await tool.handler(
        const ToolCall(
          id: 'call_modal',
          name: 'act',
          arguments: {'action': 'tap', 'ref': 1},
        ),
      );

      expect(res.ok, isFalse);
      expect(res.error?.message, contains('Confirmation modal appeared post-tap'));
      expect(res.error?.message, contains('AlertDialog: "Confirm transaction of \$50?"'));
      expect(res.error?.message, contains('Execution paused'));
    });
  });
}

class MockA11yService extends A11yService {
  bool enabled = true;
  bool tapSuccess = true;
  String screenOutline = 'Screen: package=com.example\n[1] Button "Next"';
  bool unchanged = false;
  String? modalOnProbe;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> isRestricted() async => false;

  @override
  Future<Map<String, dynamic>> tapByRef(int ref, {bool longClick = false}) async {
    if (!tapSuccess) return {'ok': false, 'message': 'Ref tap failed'};
    final label = getRefLabel(ref) ?? _extractLabelFromOutline(ref);
    if (label != null) {
      final commitWord = looksLikeCommitAction(label);
      if (commitWord != null) {
        return {
          'ok': false,
          'error': 'COMMIT_REFUSAL',
          'label': label,
          'matched': commitWord,
          'message': formatCommitRefusal(label, commitWord),
        };
      }
    }
    return {'ok': true, 'message': 'Tapped [$ref]'};
  }

  String? _extractLabelFromOutline(int ref) {
    final m = RegExp(r'\[' + RegExp.escape('$ref') + r'\](?:\s+[^\s"]+)?\s+"([^"]+)"')
        .firstMatch(screenOutline);
    return m?.group(1);
  }

  @override
  Future<Map<String, dynamic>> longPressByRef(int ref) async {
    return tapByRef(ref, longClick: true);
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
  Future<Map<String, dynamic>> probeChanged({int settleMs = 1000}) async {
    return {'ok': true, 'changed': true, 'modal': modalOnProbe};
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
    cacheOutline(screenOutline);
    return {
      'ok': true,
      'outline': screenOutline,
      'modal': modalOnProbe,
    };
  }
}
