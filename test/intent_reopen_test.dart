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
        'open_file',
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
      ]) {
        expect(isReopenable(intentMessage(action)), isFalse,
            reason: '$action should NOT be reopenable');
      }
    });

    test('raw intent: bare data Uri is reopenable (defaults to VIEW)', () {
      // The "play a local mp3" case: ACTION_VIEW on a file Uri — the system
      // chooser opens the content, nothing else happens. Re-tapping is safe.
      expect(
        isReopenable(intentMessage(
          'intent',
          args: {'url': '/storage/emulated/0/Download/song.mp3'},
        )),
        isTrue,
      );
    });

    test('raw intent: view-style android actions are reopenable', () {
      for (final androidAction in [
        'android.intent.action.VIEW',
        'android.intent.action.MAIN',
        'android.intent.action.DIAL',
        'android.intent.action.SENDTO',
        'android.media.action.MEDIA_PLAY_FROM_SEARCH',
        'android.settings.DISPLAY_SETTINGS', // settings.* prefix
        'android.settings.panel.action.WIFI', // settings panels
      ]) {
        expect(
          isReopenable(intentMessage(
            'intent',
            args: {'android_action': androidAction},
          )),
          isTrue,
          reason: '$androidAction should be reopenable',
        );
      }
    });

    test('raw intent: unknown third-party actions stay button-less', () {
      expect(
        isReopenable(intentMessage(
          'intent',
          args: {'android_action': 'com.someapp.action.SYNC'},
        )),
        isFalse,
      );
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
