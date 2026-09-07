import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/intent_service.dart';
import 'package:errand/tools/intent_tool.dart';

class MockIntentService extends IntentService {
  String? lastAction;
  String? lastAndroidAction;
  String? lastData;
  String? lastPackage;
  Map<String, String>? lastExtras;
  String? lastType;
  String returnResult = 'launched';

  @override
  Future<String> launchAction(
    String action, {
    String? androidAction,
    String? data,
    String? package,
    Map<String, String>? extras,
    String? type,
  }) async {
    lastAction = action;
    lastAndroidAction = androidAction;
    lastData = data;
    lastPackage = package;
    lastExtras = extras;
    lastType = type;
    return returnResult;
  }
}

class MockA11yService extends A11yService {
  bool enabled = true;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> hasSecureSettings() async => false;
}

void main() {
  late MockIntentService service;
  late MockA11yService a11yService;
  late Tool tool;

  setUp(() {
    service = MockIntentService();
    a11yService = MockA11yService();
    tool = intentTool(service: service, a11yService: a11yService);
  });

  group('intentTool schema', () {
    test('exposes exactly the 5 unified actions in enum', () {
      final properties = tool.parameters['properties'] as Map<String, dynamic>;
      final actionProp = properties['action'] as Map<String, dynamic>;
      final actions = List<String>.from(actionProp['enum'] as List);
      expect(actions, ['open_file', 'open_url', 'open_app', 'settings', 'intent']);
    });
  });

  group('open_file action', () {
    test('launches local file with path and detects ok result', () async {
      final call = ToolCall(
        id: 'call-1',
        name: 'intent',
        arguments: {
          'action': 'open_file',
          'path': '/storage/emulated/0/Download/audio.mp3',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_file');
      expect(service.lastData, '/storage/emulated/0/Download/audio.mp3');
      expect(result.output, contains('Opened file'));
    });

    test('passes explicit MIME type if provided', () async {
      final call = ToolCall(
        id: 'call-2',
        name: 'intent',
        arguments: {
          'action': 'open_file',
          'path': '/sdcard/doc.pdf',
          'type': 'application/pdf',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastType, 'application/pdf');
    });

    test('fails when path is missing', () async {
      final call = ToolCall(
        id: 'call-3',
        name: 'intent',
        arguments: {'action': 'open_file'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Missing "path"'));
    });
  });

  group('open_url auto-routing and schemes', () {
    test('auto-routes local path passed to open_url to open_file', () async {
      final call = ToolCall(
        id: 'call-4',
        name: 'intent',
        arguments: {
          'action': 'open_url',
          'url': '/storage/emulated/0/DCIM/photo.jpg',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_file');
      expect(service.lastData, '/storage/emulated/0/DCIM/photo.jpg');
    });

    test('opens normal https URL', () async {
      final call = ToolCall(
        id: 'call-5',
        name: 'intent',
        arguments: {
          'action': 'open_url',
          'url': 'https://flutter.dev',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_url');
      expect(service.lastData, 'https://flutter.dev');
    });

    test('opens tel: URI scheme', () async {
      final call = ToolCall(
        id: 'call-6',
        name: 'intent',
        arguments: {
          'action': 'open_url',
          'url': 'tel:+1234567890',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_url');
      expect(service.lastData, 'tel:+1234567890');
    });

    test('opens mailto: URI scheme', () async {
      final call = ToolCall(
        id: 'call-7',
        name: 'intent',
        arguments: {
          'action': 'open_url',
          'url': 'mailto:user@example.com?subject=Hello',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_url');
      expect(service.lastData, 'mailto:user@example.com?subject=Hello');
    });
  });

  group('open_app action', () {
    test('launches app with package', () async {
      final call = ToolCall(
        id: 'call-8',
        name: 'intent',
        arguments: {
          'action': 'open_app',
          'package': 'com.spotify.music',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_app');
      expect(service.lastPackage, 'com.spotify.music');
    });

    test('fails if package is missing', () async {
      final call = ToolCall(
        id: 'call-9',
        name: 'intent',
        arguments: {'action': 'open_app'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Missing "package"'));
    });

    test('throws A11yRequiredException if accessibility is disabled', () async {
      a11yService.enabled = false;
      final call = const ToolCall(
        id: 'call-a11y',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.spotify.music'},
      );
      expect(() => tool.handler(call), throwsA(isA<A11yRequiredException>()));
    });
  });

  group('settings action', () {
    test('opens known settings page', () async {
      final call = ToolCall(
        id: 'call-10',
        name: 'intent',
        arguments: {
          'action': 'settings',
          'page': 'wifi',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'intent');
      expect(service.lastAndroidAction, 'android.settings.WIFI_SETTINGS');
    });
  });

  group('backward compatibility', () {
    test('supports legacy dial action by converting to tel: open_url', () async {
      final call = ToolCall(
        id: 'call-11',
        name: 'intent',
        arguments: {
          'action': 'dial',
          'query': '123456',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_url');
      expect(service.lastData, 'tel:123456');
    });

    test('supports legacy open_maps action by converting to geo: open_url', () async {
      final call = ToolCall(
        id: 'call-12',
        name: 'intent',
        arguments: {
          'action': 'open_maps',
          'query': 'Central Park',
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'open_url');
      expect(service.lastData, contains('geo:0,0?q=Central+Park'));
    });
  });
}
