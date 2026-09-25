import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
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
  static const String _kLastSeenVersionKey = 'pref.last_seen_version';
  static const Duration checkInterval = Duration(hours: 2);
  static const Duration defaultDownloadInactivityTimeout =
      Duration(seconds: 30);
  static const Duration defaultDownloadTotalTimeout = Duration(minutes: 10);

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
  }) : _client = client ?? http.Client(),
       _appInfo = appInfo ?? AppInfoService.instance,
       _db = database ?? ErrandDatabase.instance;

  /// Holds the active update metadata if an update is available and not dismissed.
  final ValueNotifier<AppUpdateInfo?> activeUpdate =
      ValueNotifier<AppUpdateInfo?>(null);

  /// Download progress between 0.0 and 1.0; null when idle.
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  bool _isChecking = false;
  bool _isDownloading = false;
  String? _dismissedVersionThisSession;

  bool get isDownloading => _isDownloading;

  /// Initializes the service from cached state and triggers a background check
  /// if the 2-hour window has elapsed.
  Future<void> initialize() async {
    // Dismissal is intentionally session-scoped. A new app open must surface
    // an update again while that release is still newer than the installed app.
    _dismissedVersionThisSession = null;
    final cached = await loadPersistedInfo();
    if (cached != null) {
      final platformInfo = await _appInfo.getAppInfo();
      var current = cached;
      final installedVersion = platformInfo.versionName.trim();
      final hasInstalledVersion =
          installedVersion.isNotEmpty && installedVersion != '0.0.0';
      final versionChanged =
          hasInstalledVersion && installedVersion != cached.currentVersion;
      final installedAtOrPastLatest =
          hasInstalledVersion &&
          AppUpdateInfo.compareSemver(installedVersion, cached.latestVersion) >=
              0;

      if (installedAtOrPastLatest && cached.apkLocation != null) {
        _deleteFile(cached.apkLocation);
        current = cached.copyWith(
          currentVersion: installedVersion,
          clearCachedApk: true,
          clearDismissedVersion: true,
        );
      } else if (versionChanged) {
        current = cached.copyWith(currentVersion: installedVersion);
      }

      if (current != cached) {
        await _persistInfo(current);
      }

      _publishActiveUpdate(current);
    } else {
      activeUpdate.value = null;
    }
    // Background check runs asynchronously without awaiting.
    unawaited(checkUpdate());
  }

  bool _isDismissedThisSession(AppUpdateInfo info) {
    return _dismissedVersionThisSession != null &&
        AppUpdateInfo.compareSemver(
              _dismissedVersionThisSession!,
              info.latestVersion,
            ) ==
            0;
  }

  void _publishActiveUpdate(AppUpdateInfo? info) {
    if (info != null &&
        info.hasUpdate &&
        info.hasCompatibleApk &&
        !_isDismissedThisSession(info)) {
      activeUpdate.value = info;
    } else {
      activeUpdate.value = null;
    }
  }

  void _deleteFile(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Parses markdown release notes body into clean, user-facing bullet points.
  static List<String> parseReleaseNotes(String? body) {
    if (body == null || body.trim().isEmpty) return [];

    final lines = body.split('\n');
    final items = <String>[];

    for (var rawLine in lines) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;

      // Skip horizontal rules
      if (RegExp(r'^[-*_]{3,}$').hasMatch(line)) continue;

      // Skip markdown headings (# What's Changed, ### Highlights, etc.)
      if (line.startsWith('#')) continue;

      // Skip full changelog lines or comparison URLs
      if (RegExp(
        r'^\*{0,2}Full Changelog',
        caseSensitive: false,
      ).hasMatch(line)) {
        continue;
      }
      if (RegExp(
        r'^https?://github\.com/.+/compare/',
        caseSensitive: false,
      ).hasMatch(line)) {
        continue;
      }

      // Skip APK download links/asset mentions
      if (line.toLowerCase().contains('.apk') &&
          (line.startsWith('[') || line.startsWith('http'))) {
        continue;
      }

      // Strip leading bullet markers (*, -, +, •, or "1. ")
      line = line.replaceFirst(RegExp(r'^([*\-+•]|\d+[.)])\s+'), '');

      // Strip GitHub PR suffix: " by @user in https://github.com/..."
      line = line.replaceFirst(
        RegExp(r'\s+by\s+@\S+\s+in\s+https?://\S+.*$', caseSensitive: false),
        '',
      );

      // Remove markdown links [text](url) -> text
      line = line.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'),
        (m) => m[1] ?? '',
      );

      // Remove bold/italic/code markers: **bold**, *italic*, `code`
      line = line.replaceAll(RegExp(r'[*_`]{1,2}'), '');

      line = line.trim();
      if (line.isNotEmpty) {
        items.add(line);
      }
    }

    return items;
  }

  /// Extracts a SHA-256 checksum from release notes or body text.
  /// Looks for filename-associated hashes first, followed by explicit SHA-256 labels.
  static String? extractSha256(String? text, [String? targetFileName]) {
    if (text == null || text.trim().isEmpty) return null;
    if (targetFileName != null && targetFileName.trim().isNotEmpty) {
      final escaped = RegExp.escape(targetFileName.trim());
      // Pattern 1: <sha256>  <filename>
      final hashBefore = RegExp(
        r'([a-fA-F0-9]{64})\s+[*]?(' + escaped + r')',
        caseSensitive: false,
      ).firstMatch(text);
      if (hashBefore != null) return hashBefore.group(1)!.toLowerCase();

      // Pattern 2: <filename>: <sha256> or <filename> = <sha256>
      final hashAfter = RegExp(
        r'(' + escaped + r')\s*[:=]\s*([a-fA-F0-9]{64})',
        caseSensitive: false,
      ).firstMatch(text);
      if (hashAfter != null) return hashAfter.group(2)!.toLowerCase();
    }

    // Pattern 3: SHA256: <sha256> or SHA-256: <sha256> or checksum: <sha256>
    final explicit = RegExp(
      r'(?:sha-?256|checksum|hash)\s*[:=]\s*([a-fA-F0-9]{64})',
      caseSensitive: false,
    ).firstMatch(text);
    if (explicit != null) {
      return explicit.group(1)!.toLowerCase();
    }
    return null;
  }

  /// Fetches release notes from GitHub API for a specific tag or falls back to latest release.
  Future<String?> fetchReleaseNotes(String version) async {
    try {
      final cleanVersion = version.replaceFirst(RegExp(r'^[vV]'), '').trim();
      final tagUri = Uri.parse(
        'https://api.github.com/repos/Abhiram86/errand/releases/tags/v$cleanVersion',
      );
      var response = await _client
          .get(
            tagUri,
            headers: {
              'Accept': 'application/vnd.github.v3+json',
              'User-Agent': 'handy_flutter/1.0',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        response = await _client
            .get(
              Uri.parse(latestReleaseUrl),
              headers: {
                'Accept': 'application/vnd.github.v3+json',
                'User-Agent': 'handy_flutter/1.0',
              },
            )
            .timeout(const Duration(seconds: 10));
      }

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          final tag = data['tag_name'] as String?;
          if (tag == null ||
              AppUpdateInfo.compareSemver(tag, cleanVersion) == 0) {
            return data['body'] as String?;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Checks whether this is the first launch after an update (excluding fresh/first installs).
  /// If it is an update launch, returns the parsed release notes and updates the last seen version.
  /// If it is a fresh install or already-seen version, returns null.
  Future<List<String>?> checkFirstLaunchAfterUpdate() async {
    try {
      final platformInfo = await _appInfo.getAppInfo();
      final currentVersion = platformInfo.versionName.trim();
      if (currentVersion.isEmpty || currentVersion == '0.0.0') {
        return null;
      }

      final lastSeen = await _db.getSetting(_kLastSeenVersionKey);
      final cached = await loadPersistedInfo();

      if (lastSeen == null) {
        // Distinguish fresh install vs existing user updating from before this pref existed
        final hasUserData = await _db.hasAnyUserData();
        final hadOlderCached =
            cached != null &&
            (AppUpdateInfo.compareSemver(
                      currentVersion,
                      cached.currentVersion,
                    ) >
                    0 ||
                (AppUpdateInfo.compareSemver(
                          currentVersion,
                          cached.latestVersion,
                        ) ==
                        0 &&
                    AppUpdateInfo.compareSemver(
                          cached.latestVersion,
                          cached.currentVersion,
                        ) >
                        0));

        final isUpdate = hadOlderCached || hasUserData;

        // Persist current version so subsequent launches know it's already seen
        await _db.setSetting(_kLastSeenVersionKey, currentVersion);

        if (!isUpdate) {
          // Fresh install / first install: do not show release notes
          return null;
        }

        // Clean up any stale APK from previous version
        if (cached?.apkLocation != null) {
          try {
            final f = File(cached!.apkLocation!);
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }

        String? notesBody = cached?.releaseNotes;
        if (notesBody == null || notesBody.trim().isEmpty) {
          notesBody = await fetchReleaseNotes(currentVersion);
        }

        final parsed = parseReleaseNotes(notesBody);
        return parsed.isNotEmpty ? parsed : null;
      }

      // Existing last seen version is present:
      final cmp = AppUpdateInfo.compareSemver(currentVersion, lastSeen);
      if (cmp <= 0) {
        // Not a newer version launch
        return null;
      }

      // First launch after update!
      await _db.setSetting(_kLastSeenVersionKey, currentVersion);

      // Clean up any stale APK from cache
      if (cached?.apkLocation != null) {
        try {
          final f = File(cached!.apkLocation!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }

      String? notesBody;
      if (cached != null &&
          AppUpdateInfo.compareSemver(cached.latestVersion, currentVersion) ==
              0 &&
          cached.releaseNotes != null &&
          cached.releaseNotes!.trim().isNotEmpty) {
        notesBody = cached.releaseNotes;
      } else {
        notesBody = await fetchReleaseNotes(currentVersion);
      }

      final parsed = parseReleaseNotes(notesBody);
      return parsed.isNotEmpty ? parsed : null;
    } catch (_) {
      return null;
    }
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

  void _cleanStaleApkIfNeeded(AppUpdateInfo info, [String? currentVersion]) {
    if (info.apkLocation != null) {
      final isStaleVersion =
          currentVersion != null &&
          AppUpdateInfo.compareSemver(currentVersion, info.latestVersion) >= 0;
      if (!info.isCachedApkValid || isStaleVersion) {
        _deleteFile(info.apkLocation);
      }
    }
  }

  /// Checks GitHub releases API for an update if [force] is true or the 2-hour interval elapsed.
  Future<AppUpdateInfo?> checkUpdate({bool force = false}) async {
    if (_isChecking) return activeUpdate.value;
    if (force) {
      // An explicit user check should be able to surface a banner that was
      // dismissed earlier in this session.
      _dismissedVersionThisSession = null;
    }
    _isChecking = true;
    AppUpdateInfo? cachedForError;

    try {
      final existing = await loadPersistedInfo();
      final now = DateTime.now();
      final platformInfo = await _appInfo.getAppInfo();
      final currentVersion = platformInfo.versionName.trim();

      // Cached records were written using the version that was installed when
      // the check ran. Refresh it before applying the interval shortcut so an
      // update install is recognized immediately on the next launch.
      var cached = existing;
      cachedForError = cached;
      if (cached != null &&
          currentVersion.isNotEmpty &&
          currentVersion != '0.0.0' &&
          currentVersion != cached.currentVersion) {
        final installedAtOrPastLatest =
            AppUpdateInfo.compareSemver(currentVersion, cached.latestVersion) >=
            0;
        if (installedAtOrPastLatest && cached.apkLocation != null) {
          _deleteFile(cached.apkLocation);
          cached = cached.copyWith(
            currentVersion: currentVersion,
            clearCachedApk: true,
            clearDismissedVersion: true,
          );
        } else {
          cached = cached.copyWith(currentVersion: currentVersion);
        }
        await _persistInfo(cached);
      }

      if (!force && cached != null) {
        final elapsed = now.difference(cached.lastPing);
        if (elapsed < checkInterval) {
          if (cached.hasUpdate &&
              cached.hasCompatibleApk &&
              !_isDismissedThisSession(cached)) {
            activeUpdate.value = cached;
          } else {
            activeUpdate.value = null;
          }
          return cached;
        }
      }

      final response = await _client
          .get(
            Uri.parse(latestReleaseUrl),
            headers: {
              'Accept': 'application/vnd.github.v3+json',
              'User-Agent': 'handy_flutter/1.0',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _publishActiveUpdate(cached);
        return cached;
      }

      final dynamic data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        _publishActiveUpdate(cached);
        return cached;
      }

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
      String? apkLocation = cached?.apkLocation;
      DateTime? apkDownloadedAt = cached?.apkDownloadedAt;
      if (cached != null && cached.latestVersion != latestVersion) {
        _cleanStaleApkIfNeeded(cached);
        apkLocation = null;
        apkDownloadedAt = null;
      }

      final matchedSha256 = extractSha256(releaseNotes, matchedName);

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
        sha256: matchedSha256,
      );

      await _persistInfo(updated);

      _publishActiveUpdate(updated);

      return updated;
    } catch (_) {
      // Non-fatal: offline or API errors silently return cached
      _publishActiveUpdate(cachedForError);
      return cachedForError ?? activeUpdate.value;
    } finally {
      _isChecking = false;
    }
  }

  /// Downloads the APK file to cache with atomic rename and progress reporting.
  ///
  /// Verification contract: exact byte length (when the server reports one)
  /// plus SHA-256 when the release notes publish a checksum for the APK
  /// (see [extractSha256]). Releases MUST publish hashes for full
  /// verification; a hashless download is size-checked only and logs a
  /// warning. Pass [requireSha256] to fail closed (reject hashless
  /// downloads) once the release process guarantees published checksums.
  Future<String?> downloadApk(
    AppUpdateInfo info, {
    Duration inactivityTimeout = defaultDownloadInactivityTimeout,
    Duration totalTimeout = defaultDownloadTotalTimeout,
    bool requireSha256 = false,
    void Function(double progress)? onProgress,
  }) async {
    if (info.apkUrl == null || info.apkUrl!.isEmpty) return null;
    if (_isDownloading) return null;
    _isDownloading = true;
    downloadProgress.value = 0.0;

    File? tempFile;
    IOSink? sink;
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
      final streamedResponse = await _client
          .send(request)
          .timeout(inactivityTimeout);

      if (streamedResponse.statusCode != 200) {
        return null;
      }

      final contentLength = streamedResponse.contentLength ?? info.apkSize ?? 0;
      var receivedBytes = 0;
      sink = tempFile.openWrite();

      final stream = streamedResponse.stream.timeout(
        inactivityTimeout,
        onTimeout: (eventSink) {
          eventSink.addError(
            TimeoutException('APK download stalled (inactivity timeout)'),
          );
        },
      );

      // Note: .timeout() abandons the await-for but does not cancel the
      // underlying HTTP subscription; the stream drains until GC. File and
      // sink cleanup below still run, so the leak is transient bandwidth
      // only, never orphaned disk state.
      await Future.sync(() async {
        await for (final chunk in stream) {
          sink!.add(chunk);
          receivedBytes += chunk.length;
          if (contentLength > 0) {
            final p = (receivedBytes / contentLength).clamp(0.0, 1.0);
            downloadProgress.value = p;
            onProgress?.call(p);
          }
        }
        await sink!.flush();
      }).timeout(totalTimeout);

      await sink.close();
      sink = null;

      // Exact integrity verification: ensure file size matches expected size
      if (contentLength > 0 && tempFile.lengthSync() != contentLength) {
        tempFile.deleteSync();
        return null;
      }

      // SHA-256 verification when checksum is available
      final targetSha = info.sha256?.trim().toLowerCase();
      if (targetSha == null || targetSha.isEmpty) {
        if (requireSha256) {
          debugPrint(
            '[UpdateService] Rejecting ${info.apkName}: no SHA-256 checksum '
            'published (requireSha256)',
          );
          tempFile.deleteSync();
          return null;
        }
        debugPrint(
          '[UpdateService] No SHA-256 for ${info.apkName}; '
          '${contentLength > 0 ? 'size-checked only' : 'no integrity verification possible'}. '
          'Publish checksums in release notes for full verification.',
        );
      } else {
        final hashSink = Sha256().newHashSink();
        await for (final chunk in tempFile.openRead()) {
          hashSink.add(chunk);
        }
        hashSink.close();
        final digest = await hashSink.hash();
        final actualHex = digest.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        if (actualHex.toLowerCase() != targetSha) {
          tempFile.deleteSync();
          return null;
        }
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
      try {
        await sink?.close();
      } catch (_) {}
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
    final installed = await _appInfo.installApk(apkPath);
    if (installed) {
      // The package installer takes over from here. Hide this session's toast;
      // initialize/checkUpdate will reconcile the persisted state on relaunch.
      activeUpdate.value = null;
    }
    return installed;
  }

  /// Dismisses the current update for this app session only.
  Future<void> dismissUpdate() async {
    final current = activeUpdate.value;
    if (current == null) return;
    _dismissedVersionThisSession = current.latestVersion;
    activeUpdate.value = null;
  }
}
