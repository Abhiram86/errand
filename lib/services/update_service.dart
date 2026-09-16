import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/app_update_info.dart';
import 'app_info_service.dart';
import 'database.dart';

/// Background update checker and APK download manager.
class UpdateService {
  static const String latestReleaseUrl =
      'https://api.github.com/repos/Abhiram86/errand/releases/latest';
  static const String _dbKey = 'pref.app_update_info';
  static const Duration checkInterval = Duration(hours: 2);

  static final UpdateService instance = UpdateService();

  final http.Client _client;
  final AppInfoService _appInfo;
  final ErrandDatabase _db;
  final Future<Directory> Function()? cacheDirProvider;

  UpdateService({
    http.Client? client,
    AppInfoService? appInfo,
    ErrandDatabase? database,
    this.cacheDirProvider,
  })  : _client = client ?? http.Client(),
        _appInfo = appInfo ?? AppInfoService.instance,
        _db = database ?? ErrandDatabase.instance;

  /// Holds the active update metadata if an update is available and not dismissed.
  final ValueNotifier<AppUpdateInfo?> activeUpdate =
      ValueNotifier<AppUpdateInfo?>(null);

  /// Download progress between 0.0 and 1.0; null when idle.
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  bool _isChecking = false;
  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  /// Initializes the service from cached state and triggers a background check
  /// if the 2-hour window has elapsed.
  Future<void> initialize() async {
    final cached = await loadPersistedInfo();
    if (cached != null) {
      _cleanStaleApkIfNeeded(cached);
      if (cached.hasUpdate && !cached.isDismissed) {
        activeUpdate.value = cached;
      }
    }
    // Background check runs asynchronously without awaiting.
    unawaited(checkUpdate());
  }

  /// Loads persisted update info from the SQLite settings table.
  Future<AppUpdateInfo?> loadPersistedInfo() async {
    try {
      final raw = await _db.getSetting(_dbKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        return AppUpdateInfo.fromJson(map);
      }
    } catch (_) {}
    return null;
  }

  /// Saves the given [info] to SQLite.
  Future<void> _persistInfo(AppUpdateInfo info) async {
    try {
      await _db.setSetting(_dbKey, jsonEncode(info.toJson()));
    } catch (_) {}
  }

  void _cleanStaleApkIfNeeded(AppUpdateInfo info) {
    if (info.apkLocation != null && !info.isCachedApkValid) {
      try {
        final f = File(info.apkLocation!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// Checks GitHub releases API for an update if [force] is true or the 2-hour interval elapsed.
  Future<AppUpdateInfo?> checkUpdate({bool force = false}) async {
    if (_isChecking) return activeUpdate.value;
    _isChecking = true;

    try {
      final existing = await loadPersistedInfo();
      final now = DateTime.now();

      if (!force && existing != null) {
        final elapsed = now.difference(existing.lastPing);
        if (elapsed < checkInterval) {
          if (existing.hasUpdate && !existing.isDismissed) {
            activeUpdate.value = existing;
          }
          return existing;
        }
      }

      final platformInfo = await _appInfo.getAppInfo();
      final currentVersion = platformInfo.versionName;

      final response = await _client.get(
        Uri.parse(latestReleaseUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'handy_flutter/1.0',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return existing;
      }

      final dynamic data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return existing;

      final tagName = data['tag_name'] as String? ?? '';
      final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '').trim();
      final releaseNotes = data['body'] as String?;

      // Find matching APK asset for device flavor and ABI
      final assets = data['assets'];
      String? matchedUrl;
      String? matchedName;
      int? matchedSize;

      if (assets is List) {
        final flavor = platformInfo.flavor; // "full" or "lite"
        final abi = platformInfo.abi; // e.g. "arm64-v8a"

        for (final item in assets) {
          if (item is! Map) continue;
          final name = (item['name'] as String? ?? '').toLowerCase();
          if (!name.endsWith('.apk')) continue;

          // Ideal match: Errand-v0.6.1-full-arm64-v8a.apk
          if (name.contains('-$flavor-') && name.contains(abi.toLowerCase())) {
            matchedUrl = item['browser_download_url'] as String?;
            matchedName = item['name'] as String?;
            matchedSize = (item['size'] as num?)?.toInt();
            break;
          }
        }

        // Fallback: match flavor and any ARM APK (e.g. arm64-v8a or armeabi-v7a)
        if (matchedUrl == null) {
          for (final item in assets) {
            if (item is! Map) continue;
            final name = (item['name'] as String? ?? '').toLowerCase();
            if (!name.endsWith('.apk')) continue;
            if (name.contains('-$flavor-') && name.contains('arm')) {
              matchedUrl = item['browser_download_url'] as String?;
              matchedName = item['name'] as String?;
              matchedSize = (item['size'] as num?)?.toInt();
              break;
            }
          }
        }
      }

      // Preserve existing cached APK if it belongs to the same version and is valid
      String? apkLocation = existing?.apkLocation;
      DateTime? apkDownloadedAt = existing?.apkDownloadedAt;
      if (existing != null && existing.latestVersion != latestVersion) {
        _cleanStaleApkIfNeeded(existing);
        apkLocation = null;
        apkDownloadedAt = null;
      }

      final updated = AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        lastPing: now,
        releaseNotes: releaseNotes,
        apkUrl: matchedUrl,
        apkName: matchedName,
        apkLocation: apkLocation,
        apkDownloadedAt: apkDownloadedAt,
        apkSize: matchedSize,
        dismissedVersion: existing?.dismissedVersion,
      );

      await _persistInfo(updated);

      if (updated.hasUpdate && !updated.isDismissed) {
        activeUpdate.value = updated;
      } else {
        activeUpdate.value = null;
      }

      return updated;
    } catch (_) {
      // Non-fatal: offline or API errors silently return cached
      return activeUpdate.value;
    } finally {
      _isChecking = false;
    }
  }

  /// Downloads the APK file to cache with atomic rename and progress reporting.
  Future<String?> downloadApk(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (info.apkUrl == null || info.apkUrl!.isEmpty) return null;
    if (_isDownloading) return null;
    _isDownloading = true;
    downloadProgress.value = 0.0;

    File? tempFile;
    try {
      final dir = cacheDirProvider != null
          ? await cacheDirProvider!()
          : await getTemporaryDirectory();

      final updatesDir = Directory('${dir.path}/updates');
      if (!updatesDir.existsSync()) {
        updatesDir.createSync(recursive: true);
      }

      final fileName = info.apkName ?? 'Errand-v${info.latestVersion}.apk';
      final finalPath = '${updatesDir.path}/$fileName';
      final tempPath = '${updatesDir.path}/$fileName.tmp';

      tempFile = File(tempPath);
      if (tempFile.existsSync()) tempFile.deleteSync();

      final request = http.Request('GET', Uri.parse(info.apkUrl!));
      request.headers['User-Agent'] = 'handy_flutter/1.0';
      final streamedResponse = await _client.send(request);

      if (streamedResponse.statusCode != 200) {
        return null;
      }

      final contentLength = streamedResponse.contentLength ?? info.apkSize ?? 0;
      var receivedBytes = 0;
      final sink = tempFile.openWrite();

      await for (final chunk in streamedResponse.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (contentLength > 0) {
          final p = (receivedBytes / contentLength).clamp(0.0, 1.0);
          downloadProgress.value = p;
          onProgress?.call(p);
        }
      }
      await sink.flush();
      await sink.close();

      // Integrity verification: ensure file size matches expected size
      if (contentLength > 0 && tempFile.lengthSync() < contentLength) {
        tempFile.deleteSync();
        return null;
      }

      // Atomic rename to final target file
      final destFile = File(finalPath);
      if (destFile.existsSync()) destFile.deleteSync();
      await tempFile.rename(finalPath);

      // Update state in DB
      final updated = info.copyWith(
        apkLocation: finalPath,
        apkDownloadedAt: DateTime.now(),
        apkSize: destFile.lengthSync(),
      );
      await _persistInfo(updated);
      activeUpdate.value = updated;

      return finalPath;
    } catch (_) {
      if (tempFile != null && tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }
      return null;
    } finally {
      _isDownloading = false;
      downloadProgress.value = null;
    }
  }

  /// Installs the update by either launching the cached APK or downloading then installing.
  Future<bool> installUpdate(AppUpdateInfo info) async {
    String? apkPath = info.apkLocation;
    if (!info.isCachedApkValid) {
      apkPath = await downloadApk(info);
    }
    if (apkPath == null || !File(apkPath).existsSync()) {
      return false;
    }
    return await _appInfo.installApk(apkPath);
  }

  /// Marks the current update as dismissed so the toast doesn't reappear until the next release.
  Future<void> dismissUpdate() async {
    final current = activeUpdate.value;
    if (current == null) return;
    final updated = current.copyWith(
      dismissedVersion: current.latestVersion,
    );
    await _persistInfo(updated);
    activeUpdate.value = null;
  }
}
