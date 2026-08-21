import 'package:flutter_test/flutter_test.dart';
import 'package:errand/tools/intent_tool.dart';
import 'package:errand/types/message.dart';

ToolMessage intentMessage(
  String action, {
  Map<String, dynamic>? args,
  String result = 'Opened URL: https://x.dev (ok)',
}) => ToolMessage(
  id: 't1',
  text: 'tool output',
  tool: ToolInvocation(
    name: 'intent',
    args: {'action': action, ...?args},
  ),
  result: result,
);

void main() {
  group('isReopenable', () {
    test('accepts open-style successful intent actions', () {
      for (final action in [
        'open_url',
        'open_app',
        'open_maps',
        'search',
        'dial',
        'media_play',
        'email',
        'share',
        'wallpaper',
        'settings',
        'settings_panel',
      ]) {
        expect(isReopenable(intentMessage(action)), isTrue,
            reason: '$action should be reopenable');
      }
    });

    test('rejects side-effect actions', () {
      for (final action in [
        'alarm',
        'timer',
        'calendar_event',
        'uninstall',
        'system',
        'intent',
      ]) {
        expect(isReopenable(intentMessage(action)), isFalse,
            reason: '$action should NOT be reopenable');
      }
    });

    test('rejects failed results', () {
      expect(
        isReopenable(
          intentMessage('open_url', result: 'ERROR: Failed to open URL'),
        ),
        isFalse,
      );
    });

    test('rejects non-intent tools', () {
      final message = ToolMessage(
        id: 't1',
        text: 'tool output',
        tool: ToolInvocation(name: 'read', args: {'path': 'a.txt'}),
        result: 'file contents',
      );
      expect(isReopenable(message), isFalse);
    });
  });
}
