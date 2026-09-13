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
  Map<String, dynamic>? lastExtras;
  String? lastType;
  String returnResult = 'launched';

  @override
  Future<String> launchAction(
    String action, {
    String? androidAction,
    String? data,
    String? package,
    Map<String, dynamic>? extras,
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
  final bool enabled;
  final bool supported;
  MockA11yService({this.enabled = true, this.supported = true});

  @override
  Future<bool> isSupported({bool forceRefresh = false}) async => supported;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> isRestricted() async => false;
}

void main() {
  late MockIntentService service;
  late Tool tool;

  setUp(() {
    service = MockIntentService();
    // Hermetic default: never hit the real a11y MethodChannel in tests.
    tool = intentTool(
      service: service,
      a11yService: MockA11yService(enabled: true),
    );
  });

  group('intentTool schema', () {
    test('exposes the unified actions in enum including docs', () {
      final properties = tool.parameters['properties'] as Map<String, dynamic>;
      final actionProp = properties['action'] as Map<String, dynamic>;
      final actions = List<String>.from(actionProp['enum'] as List);
      expect(actions, [
        'open_file',
        'open_url',
        'open_app',
        'settings',
        'intent',
        'docs',
      ]);
      expect(properties.containsKey('name'), isTrue);
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
        arguments: {'action': 'open_url', 'url': 'https://flutter.dev'},
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
        arguments: {'action': 'open_url', 'url': 'tel:+1234567890'},
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
        arguments: {'action': 'open_app', 'package': 'com.spotify.music'},
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

    test('includes disabled notice when a11y is off', () async {
      final mockA11y = MockA11yService(enabled: false);
      final customTool = intentTool(service: service, a11yService: mockA11y);
      final call = ToolCall(
        id: 'call-a11y-off',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.whatsapp'},
      );
      final result = await customTool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('[NOTICE: SCREEN ACCESS PAUSED]'));
      expect(result.output, contains('Launched app: WhatsApp (com.whatsapp'));
    });

    test('omits disabled notice when a11y is on', () async {
      final mockA11y = MockA11yService(enabled: true);
      final customTool = intentTool(service: service, a11yService: mockA11y);
      final call = ToolCall(
        id: 'call-a11y-on',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.whatsapp'},
      );
      final result = await customTool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, isNot(contains('[NOTICE: SCREEN ACCESS PAUSED]')));
      expect(result.output, contains('Launched app: WhatsApp (com.whatsapp'));
    });
  });

  group('settings action', () {
    test('opens known settings page', () async {
      final call = ToolCall(
        id: 'call-10',
        name: 'intent',
        arguments: {'action': 'settings', 'page': 'wifi'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastAction, 'intent');
      expect(service.lastAndroidAction, 'android.settings.WIFI_SETTINGS');
    });
  });

  group('normalized custom intents', () {
    test(
      'supports legacy dial action by converting to tel: open_url',
      () async {
        final call = ToolCall(
          id: 'call-11',
          name: 'intent',
          arguments: {'action': 'dial', 'query': '123456'},
        );
        final result = await tool.handler(call);
        expect(result.ok, isTrue);
        expect(service.lastAction, 'open_url');
        expect(service.lastData, 'tel:123456');
      },
    );

    test(
      'supports legacy open_maps action by converting to geo: open_url',
      () async {
        final call = ToolCall(
          id: 'call-12',
          name: 'intent',
          arguments: {'action': 'open_maps', 'query': 'Central Park'},
        );
        final result = await tool.handler(call);
        expect(result.ok, isTrue);
        expect(service.lastAction, 'open_url');
        expect(service.lastData, contains('geo:0,0?q=Central+Park'));
      },
    );

    test(
      'passes a normalized custom intent without synthesizing fields',
      () async {
        final call = ToolCall(
          id: 'call-alarm',
          name: 'intent',
          arguments: {
            'action': 'intent',
            'android_action': 'android.intent.action.SET_ALARM',
            'package': 'com.google.android.deskclock',
            'extras': {
              'android.intent.extra.alarm.HOUR': 7,
              'android.intent.extra.alarm.MINUTES': 30,
              'android.intent.extra.alarm.MESSAGE': 'Morning Workout',
              'android.intent.extra.alarm.SKIP_UI': true,
            },
          },
        );
        final result = await tool.handler(call);
        expect(result.ok, isTrue);
        expect(service.lastAction, 'intent');
        expect(service.lastAndroidAction, 'android.intent.action.SET_ALARM');
        expect(service.lastPackage, 'com.google.android.deskclock');
        expect(service.lastExtras?['android.intent.extra.alarm.HOUR'], 7);
        expect(service.lastExtras?['android.intent.extra.alarm.MINUTES'], 30);
        expect(
          service.lastExtras?['android.intent.extra.alarm.MESSAGE'],
          'Morning Workout',
        );
        expect(service.lastExtras?['android.intent.extra.alarm.SKIP_UI'], true);
        expect(
          service.lastExtras,
          isNot(contains('android.intent.extra.HOUR')),
        );
      },
    );

    test(
      'passes calendar insertion fields and typed timestamps unchanged',
      () async {
        final call = ToolCall(
          id: 'call-calendar',
          name: 'intent',
          arguments: {
            'action': 'intent',
            'android_action': 'android.intent.action.INSERT',
            'url': 'content://com.android.calendar/events',
            'type': 'vnd.android.cursor.dir/event',
            'extras': {
              'title': 'Lunch',
              'beginTime': 1758000000000,
              'endTime': 1758003600000,
              'allDay': false,
            },
          },
        );
        final result = await tool.handler(call);
        expect(result.ok, isTrue);
        expect(service.lastAction, 'intent');
        expect(service.lastAndroidAction, 'android.intent.action.INSERT');
        expect(service.lastData, 'content://com.android.calendar/events');
        expect(service.lastType, 'vnd.android.cursor.dir/event');
        expect(service.lastExtras?['beginTime'], 1758000000000);
        expect(service.lastExtras?['endTime'], 1758003600000);
        expect(service.lastExtras?['allDay'], false);
      },
    );

    test('rejects a custom intent without an action or data URI', () async {
      final call = ToolCall(
        id: 'call-invalid-intent',
        name: 'intent',
        arguments: {'action': 'intent'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Missing intent target'));
    });

    test(
      'reports unsupported extra values so the agent can correct them',
      () async {
        final call = ToolCall(
          id: 'call-invalid-extra',
          name: 'intent',
          arguments: {
            'action': 'intent',
            'android_action': 'com.example.ACTION',
            'extras': {
              'payload': {'nested': true},
            },
          },
        );
        final result = await tool.handler(call);
        expect(result.ok, isFalse);
        expect(result.errorMessage, contains('Unsupported intent extra value'));
        expect(result.errorMessage, contains('payload'));
      },
    );

    test('safely ignores null extra values without reporting error', () async {
      final call = ToolCall(
        id: 'call-null-extra',
        name: 'intent',
        arguments: {
          'action': 'intent',
          'android_action': 'com.example.ACTION',
          'extras': {'valid_key': 'valid_value', 'nullable_key': null},
        },
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(service.lastExtras?['valid_key'], 'valid_value');
      expect(service.lastExtras?.containsKey('nullable_key'), isFalse);
    });
  });

  group('flavor support and screen access notice', () {
    test(
      'omits paused notice when a11y is unsupported (lite flavor)',
      () async {
        final liteTool = intentTool(
          service: service,
          a11yService: MockA11yService(enabled: false, supported: false),
        );
        final call = ToolCall(
          id: 'call-lite',
          name: 'intent',
          arguments: {'action': 'open_url', 'url': 'https://flutter.dev'},
        );
        final result = await liteTool.handler(call);
        expect(result.ok, isTrue);
        expect(
          result.output,
          isNot(contains('[NOTICE: SCREEN ACCESS PAUSED]')),
        );
      },
    );

    test('includes paused notice when a11y is supported but disabled (full flavor)', () async {
      final fullTool = intentTool(
        service: service,
        a11yService: MockA11yService(enabled: false, supported: true),
      );
      final call = ToolCall(
        id: 'call-full',
        name: 'intent',
        arguments: {'action': 'open_url', 'url': 'https://flutter.dev'},
      );
      final result = await fullTool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('[NOTICE: SCREEN ACCESS PAUSED]'));
    });
  });

  group('docs action', () {
    tearDown(() {
      intentDocs.clear();
      intentDocs.addAll(kDefaultIntentDocs);
    });

    test('returns empty message when no name is passed and registry is empty', () async {
      intentDocs.clear();
      final call = ToolCall(
        id: 'call-docs-empty',
        name: 'intent',
        arguments: {'action': 'docs'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('No intent documentation currently available'));
    });

    test('returns failure when looking up unindexed topic', () async {
      final call = ToolCall(
        id: 'call-docs-missing',
        name: 'intent',
        arguments: {'action': 'docs', 'name': 'unknown_intent'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.toText(), contains('No intent documentation found for "unknown_intent"'));
    });

    test('returns alarm definition with hour, minutes, skip_ui, and days', () async {
      final call = ToolCall(
        id: 'call-docs-alarm',
        name: 'intent',
        arguments: {'action': 'docs', 'name': 'ALARM'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('android.intent.action.SET_ALARM'));
      expect(result.output, contains('android.intent.extra.alarm.HOUR'));
      expect(result.output, contains('android.intent.extra.alarm.MINUTES'));
      expect(result.output, contains('android.intent.extra.alarm.SKIP_UI'));
      expect(result.output, contains('android.intent.extra.alarm.DAYS'));
    });

    test('returns calendar definition with insert, beginTime, endTime, and user confirmation note', () async {
      final call = ToolCall(
        id: 'call-docs-cal',
        name: 'intent',
        arguments: {'action': 'docs', 'name': 'Calendar'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('android.intent.action.INSERT'));
      expect(result.output, contains('vnd.android.cursor.item/event'));
      expect(result.output, contains('beginTime'));
      expect(result.output, contains('endTime'));
      expect(result.output, contains('Save'));
    });

    test('returns location definition with google.navigation, geo, and streetview', () async {
      final call = ToolCall(
        id: 'call-docs-loc',
        name: 'intent',
        arguments: {'action': 'docs', 'name': 'location'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('google.navigation:'));
      expect(result.output, contains('geo:0,0?q='));
      expect(result.output, contains('google.streetview:'));
    });

    test('lists available topics including alarm, calendar, timer, location when name is omitted', () async {
      final call = ToolCall(
        id: 'call-docs-list',
        name: 'intent',
        arguments: {'action': 'docs'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('alarm'));
      expect(result.output, contains('calendar'));
      expect(result.output, contains('timer'));
      expect(result.output, contains('location'));
    });
  });
}
