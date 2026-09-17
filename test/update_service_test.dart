import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:errand/models/app_update_info.dart';
import 'package:errand/services/app_info_service.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/update_service.dart';

class FakeAppInfoService extends AppInfoService {
  final String version;
  final String pkg;
  final String abiType;
  String? installedPath;

  FakeAppInfoService({
    this.version = '0.6.0',
    this.pkg = 'com.errand.errand',
    this.abiType = 'arm64-v8a',
  });

  @override
  Future<String?> getVersion() async => version;

  @override
  Future<AppPlatformInfo> getAppInfo() async =>
      AppPlatformInfo(versionName: version, packageName: pkg, abi: abiType);

  @override
  Future<bool> installApk(String filePath) async {
    installedPath = filePath;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ErrandDatabase db;
  late Directory tempDir;

  setUp(() async {
    db = ErrandDatabase.inMemory();
    tempDir = await Directory.systemTemp.createTemp('errand_update_test_');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('AppUpdateInfo semver & TTL checks', () {
    test('compareSemver handles v-prefix, sub-versions, and pre-release', () {
      expect(AppUpdateInfo.compareSemver('v0.6.1', '0.6.0'), 1);
      expect(AppUpdateInfo.compareSemver('0.6.0', 'v0.6.0'), 0);
      expect(AppUpdateInfo.compareSemver('0.5.9', '0.6.0'), -1);
      expect(AppUpdateInfo.compareSemver('1.0.0', '0.9.9'), 1);
      expect(AppUpdateInfo.compareSemver('v0.6.1-beta', '0.6.0'), 1);
      expect(AppUpdateInfo.compareSemver('v0.6.0', '0.6.0-beta'), 0);
    });

    test('isCachedApkValid enforces 2-day TTL and file presence', () {
      final validFile = File('${tempDir.path}/test.apk')
        ..writeAsBytesSync([1, 2, 3]);

      final infoValid = AppUpdateInfo(
        currentVersion: '0.6.0',
        latestVersion: '0.6.1',
        lastPing: DateTime.now(),
        apkLocation: validFile.path,
        apkDownloadedAt: DateTime.now().subtract(const Duration(hours: 24)),
        apkSize: 3,
      );
      expect(infoValid.isCachedApkValid, isTrue);

      final infoExpired = AppUpdateInfo(
        currentVersion: '0.6.0',
        latestVersion: '0.6.1',
        lastPing: DateTime.now(),
        apkLocation: validFile.path,
        apkDownloadedAt: DateTime.now().subtract(const Duration(days: 3)),
        apkSize: 3,
      );
      expect(infoExpired.isCachedApkValid, isFalse);

      final infoMissingFile = AppUpdateInfo(
        currentVersion: '0.6.0',
        latestVersion: '0.6.1',
        lastPing: DateTime.now(),
        apkLocation: '${tempDir.path}/nonexistent.apk',
        apkDownloadedAt: DateTime.now(),
        apkSize: 3,
      );
      expect(infoMissingFile.isCachedApkValid, isFalse);
    });

    test('JSON serialization round-trip', () {
      final now = DateTime.now();
      final original = AppUpdateInfo(
        currentVersion: '0.6.0',
        latestVersion: '0.6.1',
        lastPing: now,
        releaseNotes: 'Fixed bugs and improved performance',
        apkUrl: 'https://example.com/app.apk',
        apkName: 'Errand-v0.6.1-full-arm64-v8a.apk',
        apkLocation: '/cache/app.apk',
        apkDownloadedAt: now,
        apkSize: 1024,
        dismissedVersion: '0.6.1',
      );

      final json = original.toJson();
      final restored = AppUpdateInfo.fromJson(json);

      expect(restored.currentVersion, original.currentVersion);
      expect(restored.latestVersion, original.latestVersion);
      expect(restored.releaseNotes, original.releaseNotes);
      expect(restored.apkUrl, original.apkUrl);
      expect(restored.apkName, original.apkName);
      expect(restored.apkLocation, original.apkLocation);
      expect(restored.apkSize, original.apkSize);
      expect(restored.dismissedVersion, original.dismissedVersion);
      expect(restored.isDismissed, isTrue);
    });
  });

  group('UpdateService GitHub release checking', () {
    test('detects update and matches full arm64-v8a flavor asset', () async {
      final fakeGitHubJson = jsonEncode({
        'tag_name': 'v0.6.1',
        'body': 'New features in 0.6.1',
        'assets': [
          {
            'name': 'Errand-v0.6.1-full-arm64-v8a.apk',
            'size': 25000000,
            'browser_download_url': 'https://github.com/Abhiram86/errand/releases/download/v0.6.1/Errand-v0.6.1-full-arm64-v8a.apk',
          },
          {
            'name': 'Errand-v0.6.1-lite-arm64-v8a.apk',
            'size': 24000000,
            'browser_download_url': 'https://github.com/Abhiram86/errand/releases/download/v0.6.1/Errand-v0.6.1-lite-arm64-v8a.apk',
          },
        ],
      });

      final mockClient = MockClient((request) async {
        if (request.url.toString() == UpdateService.latestReleaseUrl) {
          return http.Response(fakeGitHubJson, 200);
        }
        return http.Response('Not found', 404);
      });

      final appInfo = FakeAppInfoService(
        version: '0.6.0',
        pkg: 'com.errand.errand', // Full flavor
        abiType: 'arm64-v8a',
      );

      final service = UpdateService(
        client: mockClient,
        appInfo: appInfo,
        database: db,
        cacheDirProvider: () async => tempDir,
      );

      final result = await service.checkUpdate();
      expect(result, isNotNull);
      expect(result!.latestVersion, '0.6.1');
      expect(result.hasUpdate, isTrue);
      expect(result.apkName, 'Errand-v0.6.1-full-arm64-v8a.apk');
      expect(service.activeUpdate.value, isNotNull);
    });

    test('detects update and matches lite armeabi-v7a flavor asset', () async {
      final fakeGitHubJson = jsonEncode({
        'tag_name': 'v0.6.1',
        'body': 'Lite release notes',
        'assets': [
          {
            'name': 'Errand-v0.6.1-full-armeabi-v7a.apk',
            'size': 25000000,
            'browser_download_url': 'https://github.com/download/full-v7a.apk',
          },
          {
            'name': 'Errand-v0.6.1-lite-armeabi-v7a.apk',
            'size': 24000000,
            'browser_download_url': 'https://github.com/download/lite-v7a.apk',
          },
        ],
      });

      final mockClient = MockClient((request) async {
        return http.Response(fakeGitHubJson, 200);
      });

      final appInfo = FakeAppInfoService(
        version: '0.6.0',
        pkg: 'com.errand.errand.lite', // Lite flavor
        abiType: 'armeabi-v7a',
      );

      final service = UpdateService(
        client: mockClient,
        appInfo: appInfo,
        database: db,
        cacheDirProvider: () async => tempDir,
      );

      final result = await service.checkUpdate();
      expect(result, isNotNull);
      expect(result!.apkName, 'Errand-v0.6.1-lite-armeabi-v7a.apk');
      expect(result.apkUrl, 'https://github.com/download/lite-v7a.apk');
    });

    test(
      'skips network check if elapsed time is under 2 hours unless force=true',
      () async {
        var requestCount = 0;
        final mockClient = MockClient((request) async {
          requestCount++;
          return http.Response(
            jsonEncode({'tag_name': 'v0.6.1', 'assets': []}),
            200,
          );
        });

        final appInfo = FakeAppInfoService();
        final service = UpdateService(
          client: mockClient,
          appInfo: appInfo,
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        // First check: hits network
        await service.checkUpdate();
        expect(requestCount, 1);

        // Immediate second check: uses cached state, does not hit network
        await service.checkUpdate();
        expect(requestCount, 1);

        // Force check: hits network again
        await service.checkUpdate(force: true);
        expect(requestCount, 2);
      },
    );

    test(
      'downloads APK to .tmp and renames to final destination atomically',
      () async {
        final apkBytes = List<int>.generate(1024, (i) => i % 256);

        final mockClient = MockClient((request) async {
          if (request.url.toString() ==
              'https://github.com/download/update.apk') {
            return http.Response.bytes(
              apkBytes,
              200,
              headers: {'content-length': '${apkBytes.length}'},
            );
          }
          return http.Response('Not found', 404);
        });

        final appInfo = FakeAppInfoService();
        final service = UpdateService(
          client: mockClient,
          appInfo: appInfo,
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        final updateInfo = AppUpdateInfo(
          currentVersion: '0.6.0',
          latestVersion: '0.6.1',
          lastPing: DateTime.now(),
          apkUrl: 'https://github.com/download/update.apk',
          apkName: 'Errand-v0.6.1-full-arm64-v8a.apk',
          apkSize: apkBytes.length,
        );

        final downloadedPath = await service.downloadApk(updateInfo);
        expect(downloadedPath, isNotNull);

        final finalFile = File(downloadedPath!);
        expect(finalFile.existsSync(), isTrue);
        expect(finalFile.lengthSync(), apkBytes.length);

        // .tmp file should no longer exist after atomic rename
        expect(File('$downloadedPath.tmp').existsSync(), isFalse);

        // Now installing should directly use the cached APK without re-downloading
        final installSuccess = await service.installUpdate(
          service.activeUpdate.value!,
        );
        expect(installSuccess, isTrue);
        expect(appInfo.installedPath, finalFile.path);
        expect(service.activeUpdate.value, isNull);
      },
    );

    test(
      'dismissing an update clears activeUpdate for the current session',
      () async {
        final fakeGitHubJson = jsonEncode({'tag_name': 'v0.6.1', 'assets': []});

        final service = UpdateService(
          client: MockClient((_) async => http.Response(fakeGitHubJson, 200)),
          appInfo: FakeAppInfoService(),
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        await service.checkUpdate();
        // A release without a device-compatible APK is not actionable.
        expect(service.activeUpdate.value, isNull);

        final actionableRelease = jsonEncode({
          'tag_name': 'v0.6.1',
          'assets': [
            {
              'name': 'Errand-v0.6.1-full-arm64-v8a.apk',
              'size': 10,
              'browser_download_url': 'https://example.com/update.apk',
            },
          ],
        });
        final actionableService = UpdateService(
          client: MockClient(
            (_) async => http.Response(actionableRelease, 200),
          ),
          appInfo: FakeAppInfoService(),
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        await actionableService.checkUpdate(force: true);
        expect(actionableService.activeUpdate.value, isNotNull);

        await actionableService.dismissUpdate();
        expect(actionableService.activeUpdate.value, isNull);

        // An explicit check can surface the dismissed release again.
        await actionableService.checkUpdate(force: true);
        expect(actionableService.activeUpdate.value, isNotNull);
      },
    );

    test(
      'initialize re-surfaces a dismissed release on a new app open',
      () async {
        final release = jsonEncode({
          'tag_name': 'v0.6.1',
          'assets': [
            {
              'name': 'Errand-v0.6.1-full-arm64-v8a.apk',
              'size': 10,
              'browser_download_url': 'https://example.com/update.apk',
            },
          ],
        });
        final client = MockClient((_) async => http.Response(release, 200));

        final firstService = UpdateService(
          client: client,
          appInfo: FakeAppInfoService(),
          database: db,
          cacheDirProvider: () async => tempDir,
        );
        await firstService.checkUpdate(force: true);
        await firstService.dismissUpdate();
        expect(firstService.activeUpdate.value, isNull);

        final reopenedService = UpdateService(
          client: client,
          appInfo: FakeAppInfoService(),
          database: db,
          cacheDirProvider: () async => tempDir,
        );
        await reopenedService.initialize();
        expect(reopenedService.activeUpdate.value, isNotNull);
      },
    );

    test(
      'initialize clears cached APK state after the app has updated',
      () async {
        final staleApk = File('${tempDir.path}/stale.apk')
          ..writeAsBytesSync(List<int>.filled(10, 1));
        await db.setSetting(
          'pref.app_update_info',
          jsonEncode({
            'current_version': '0.6.0',
            'latest_version': '0.6.1',
            'last_ping': DateTime.now().millisecondsSinceEpoch,
            'apk_url': 'https://example.com/update.apk',
            'apk_location': staleApk.path,
            'apk_downloaded_at': DateTime.now().millisecondsSinceEpoch,
            'apk_size': 10,
          }),
        );

        final service = UpdateService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'tag_name': 'v0.6.1', 'assets': []}),
              200,
            ),
          ),
          appInfo: FakeAppInfoService(version: '0.6.1'),
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        await service.initialize();
        final persisted = await service.loadPersistedInfo();
        expect(service.activeUpdate.value, isNull);
        expect(staleApk.existsSync(), isFalse);
        expect(persisted!.currentVersion, '0.6.1');
        expect(persisted.apkLocation, isNull);
        expect(persisted.apkDownloadedAt, isNull);
      },
    );
  });

  group('UpdateService release notes & first launch detection', () {
    test(
      'parseReleaseNotes parses github changelog markdown into clean items',
      () {
        const sample = '''
## What's Changed
* feat(models, ui): sort models by release date by @Abhiram86 in https://github.com/Abhiram86/errand/pull/15
* Fix: **keyboard dismiss** on back press by @someone in https://github.com/Abhiram86/errand/pull/14
- Another enhancement: `code` support
1. First numbered item

**Full Changelog**: https://github.com/Abhiram86/errand/compare/v0.6.0...v0.6.1
[Errand-v0.6.1.apk](https://github.com/download/Errand.apk)
---
''';

        final items = UpdateService.parseReleaseNotes(sample);
        expect(items, [
          'feat(models, ui): sort models by release date',
          'Fix: keyboard dismiss on back press',
          'Another enhancement: code support',
          'First numbered item',
        ]);
      },
    );

    test('parseReleaseNotes returns empty list for null or empty body', () {
      expect(UpdateService.parseReleaseNotes(null), isEmpty);
      expect(UpdateService.parseReleaseNotes('   \n\n  '), isEmpty);
    });

    test(
      'fetchReleaseNotes does not label a different release as requested',
      () async {
        final client = MockClient((request) async {
          if (request.url.path.contains('/releases/tags/')) {
            return http.Response('Not found', 404);
          }
          return http.Response(
            jsonEncode({'tag_name': 'v0.6.2', 'body': 'Older notes'}),
            200,
          );
        });
        final service = UpdateService(
          client: client,
          appInfo: FakeAppInfoService(),
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        expect(await service.fetchReleaseNotes('0.6.4'), isNull);
      },
    );

    test(
      'checkFirstLaunchAfterUpdate ignores fresh install and persists version',
      () async {
        final appInfo = FakeAppInfoService(version: '0.6.1');
        final service = UpdateService(
          client: MockClient((_) async => http.Response('{}', 200)),
          appInfo: appInfo,
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        // On a fresh install, DB has no user data and no last seen version
        final notes = await service.checkFirstLaunchAfterUpdate();
        expect(notes, isNull);

        // Now last seen version is stored
        final lastSeen = await db.getSetting('pref.last_seen_version');
        expect(lastSeen, '0.6.1');

        // Subsequent launch of the same version also returns null
        final secondLaunchNotes = await service.checkFirstLaunchAfterUpdate();
        expect(secondLaunchNotes, isNull);
      },
    );

    test('checkFirstLaunchAfterUpdate detects update when lastSeen is older version', () async {
      // Setup existing last seen version (e.g. user was previously running 0.6.0)
      await db.setSetting('pref.last_seen_version', '0.6.0');

      // Cache release notes from when update was checked/downloaded in 0.6.0
      await db.setSetting(
        'pref.app_update_info',
        jsonEncode({
          'current_version': '0.6.0',
          'latest_version': '0.6.1',
          'last_ping': DateTime.now().millisecondsSinceEpoch,
          'release_notes': '* Added sorting by date\n* Fixed UI bug',
        }),
      );

      final appInfo = FakeAppInfoService(version: '0.6.1');
      final service = UpdateService(
        client: MockClient((_) async => http.Response('{}', 200)),
        appInfo: appInfo,
        database: db,
        cacheDirProvider: () async => tempDir,
      );

      final notes = await service.checkFirstLaunchAfterUpdate();
      expect(notes, isNotNull);
      expect(notes, ['Added sorting by date', 'Fixed UI bug']);

      // Last seen version is updated to 0.6.1
      expect(await db.getSetting('pref.last_seen_version'), '0.6.1');

      // Next launch on 0.6.1 returns null
      final nextLaunch = await service.checkFirstLaunchAfterUpdate();
      expect(nextLaunch, isNull);
    });

    test('checkFirstLaunchAfterUpdate falls back to GitHub API if cached notes missing', () async {
      await db.setSetting('pref.last_seen_version', '0.6.0');

      final fakeReleaseJson = jsonEncode({
        'tag_name': 'v0.6.1',
        'body': '## Release 0.6.1\n- Fetched from GitHub API\n- Another improvement',
      });

      final mockClient = MockClient((request) async {
        return http.Response(fakeReleaseJson, 200);
      });

      final appInfo = FakeAppInfoService(version: '0.6.1');
      final service = UpdateService(
        client: mockClient,
        appInfo: appInfo,
        database: db,
        cacheDirProvider: () async => tempDir,
      );

      final notes = await service.checkFirstLaunchAfterUpdate();
      expect(notes, isNotNull);
      expect(notes, ['Fetched from GitHub API', 'Another improvement']);
    });

    test(
      'checkFirstLaunchAfterUpdate cleans up stale APK upon update launch',
      () async {
        await db.setSetting('pref.last_seen_version', '0.6.0');

        final staleApk = File('${tempDir.path}/stale.apk')
          ..writeAsStringSync('apk content');
        expect(staleApk.existsSync(), isTrue);

        await db.setSetting(
          'pref.app_update_info',
          jsonEncode({
            'current_version': '0.6.0',
            'latest_version': '0.6.1',
            'last_ping': DateTime.now().millisecondsSinceEpoch,
            'apk_location': staleApk.path,
            'release_notes': '* New release notes',
          }),
        );

        final appInfo = FakeAppInfoService(version: '0.6.1');
        final service = UpdateService(
          client: MockClient((_) async => http.Response('{}', 200)),
          appInfo: appInfo,
          database: db,
          cacheDirProvider: () async => tempDir,
        );

        final notes = await service.checkFirstLaunchAfterUpdate();
        expect(notes, isNotNull);
        expect(staleApk.existsSync(), isFalse);
      },
    );
  });
}
