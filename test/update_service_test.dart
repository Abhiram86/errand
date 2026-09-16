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
  Future<AppPlatformInfo> getAppInfo() async => AppPlatformInfo(
        versionName: version,
        packageName: pkg,
        abi: abiType,
      );

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
      final validFile = File('${tempDir.path}/test.apk')..writeAsBytesSync([1, 2, 3]);

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
        ]
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
        ]
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

    test('skips network check if elapsed time is under 2 hours unless force=true', () async {
      var requestCount = 0;
      final mockClient = MockClient((request) async {
        requestCount++;
        return http.Response(jsonEncode({
          'tag_name': 'v0.6.1',
          'assets': [],
        }), 200);
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
    });

    test('downloads APK to .tmp and renames to final destination atomically', () async {
      final apkBytes = List<int>.generate(1024, (i) => i % 256);

      final mockClient = MockClient((request) async {
        if (request.url.toString() == 'https://github.com/download/update.apk') {
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
      final installSuccess = await service.installUpdate(service.activeUpdate.value!);
      expect(installSuccess, isTrue);
      expect(appInfo.installedPath, finalFile.path);
    });

    test('dismissing an update clears activeUpdate and persists dismissal', () async {
      final fakeGitHubJson = jsonEncode({
        'tag_name': 'v0.6.1',
        'assets': [],
      });

      final service = UpdateService(
        client: MockClient((_) async => http.Response(fakeGitHubJson, 200)),
        appInfo: FakeAppInfoService(),
        database: db,
        cacheDirProvider: () async => tempDir,
      );

      await service.checkUpdate();
      expect(service.activeUpdate.value, isNotNull);

      await service.dismissUpdate();
      expect(service.activeUpdate.value, isNull);

      // Re-checking does not surface the dismissed update
      await service.checkUpdate(force: true);
      expect(service.activeUpdate.value, isNull);
    });
  });
}
