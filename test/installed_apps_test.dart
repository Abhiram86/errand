import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/installed_apps_service.dart';
import 'package:errand/services/intent_service.dart';
import 'package:errand/tools/intent_tool.dart';

class MockFailingIntentService extends IntentService {
  @override
  Future<String> launchAction(
    String action, {
    String? androidAction,
    String? data,
    String? package,
    Map<String, String>? extras,
    String? type,
  }) async {
    if (package == 'com.bt.bms' || package == 'com.google.android.apps.youtube.music') {
      return 'launched';
    }
    throw PlatformException(code: 'NO_HANDLER', message: 'No activity found for pkg=$package');
  }
}

void main() {
  group('InstalledAppsService', () {
    late InstalledAppsService service;

    setUp(() {
      service = InstalledAppsService();
      service.setAppsForTesting([
        const InstalledApp(package: 'com.bt.bms', label: 'BookMyShow'),
        const InstalledApp(package: 'com.google.android.apps.youtube.music', label: 'YT Music'),
        const InstalledApp(package: 'com.google.android.youtube', label: 'YouTube'),
        const InstalledApp(package: 'com.spotify.music', label: 'Spotify'),
        const InstalledApp(package: 'in.swiggy.android', label: 'Swiggy'),
        const InstalledApp(package: 'com.application.zomato', label: 'Zomato'),
        const InstalledApp(package: 'com.ubercab', label: 'Uber'),
        const InstalledApp(package: 'com.whatsapp', label: 'WhatsApp'),
        const InstalledApp(package: 'org.telegram.messenger', label: 'Telegram'),
        const InstalledApp(package: 'com.android.chrome', label: 'Chrome'),
        const InstalledApp(package: 'org.mozilla.firefox', label: 'Firefox'),
      ]);
    });

    test('getLabel resolves cached label', () {
      expect(service.getLabel('com.bt.bms'), 'BookMyShow');
      expect(service.getLabel('com.google.android.apps.youtube.music'), 'YT Music');
      expect(service.getLabel('com.spotify.music'), 'Spotify');
    });

    test('getLabel falls back to clean package name for unknown package', () {
      expect(service.getLabel('com.duolingo'), 'Duolingo');
      expect(service.getLabel('org.videolan.vlc'), 'Videolan');
    });

    test('findExact matches by package or label or normalized alias', () {
      expect(service.findExact('com.bt.bms')?.label, 'BookMyShow');
      expect(service.findExact('BookMyShow')?.package, 'com.bt.bms');
      expect(service.findExact('bookmyshow')?.package, 'com.bt.bms');
      expect(service.findExact('yt music')?.package, 'com.google.android.apps.youtube.music');
      expect(service.findExact('YTMusic')?.package, 'com.google.android.apps.youtube.music');
    });

    test('findBestMatches returns top matched apps on misspelled package or query', () {
      final bmsMatches = service.findBestMatches('com.bookmyshow');
      expect(bmsMatches.isNotEmpty, isTrue);
      expect(bmsMatches.first.package, 'com.bt.bms');
      expect(bmsMatches.first.label, 'BookMyShow');

      final musicMatches = service.findBestMatches('music');
      expect(musicMatches.map((a) => a.label), containsAll(['YT Music', 'Spotify']));

      final ytMatches = service.findBestMatches('youtube music');
      expect(ytMatches.isNotEmpty, isTrue);
      expect(ytMatches.first.package, 'com.google.android.apps.youtube.music');
    });
  });

  group('intentTool open_app with InstalledAppsService', () {
    late InstalledAppsService appsService;
    late MockFailingIntentService intentService;
    late Tool tool;

    setUp(() {
      appsService = InstalledAppsService();
      appsService.setAppsForTesting([
        const InstalledApp(package: 'com.bt.bms', label: 'BookMyShow'),
        const InstalledApp(package: 'com.google.android.apps.youtube.music', label: 'YT Music'),
        const InstalledApp(package: 'com.google.android.youtube', label: 'YouTube'),
        const InstalledApp(package: 'com.spotify.music', label: 'Spotify'),
      ]);
      intentService = MockFailingIntentService();
      tool = intentTool(service: intentService, installedAppsService: appsService);
    });

    test('launches app and formats human label in result output', () async {
      const call = ToolCall(
        id: '1',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.bt.bms'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Launched app: BookMyShow (com.bt.bms'));
    });

    test('auto-resolves app alias (e.g. BookMyShow) to package', () async {
      const call = ToolCall(
        id: '2',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'BookMyShow'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Launched app: BookMyShow (com.bt.bms'));
    });

    test('returns top matching installed apps when target package is not found', () async {
      const call = ToolCall(
        id: '3',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.bookmyshow'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Failed to launch app "com.bookmyshow": package not found'));
      expect(result.errorMessage, contains('Top matching installed apps on this device:'));
      expect(result.errorMessage, contains('BookMyShow (com.bt.bms)'));
    });

    test('returns suggestions when model guesses wrong yt music package', () async {
      const call = ToolCall(
        id: '4',
        name: 'intent',
        arguments: {'action': 'open_app', 'package': 'com.youtube.music'},
      );
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('YT Music (com.google.android.apps.youtube.music)'));
    });
  });
}
