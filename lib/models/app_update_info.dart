import 'dart:io';

/// Holds persisted update state and cached APK metadata.
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final DateTime lastPing;
  final String? releaseNotes;
  final String? apkUrl;
  final String? apkName;
  final String? apkLocation;
  final DateTime? apkDownloadedAt;
  final int? apkSize;
  final String? dismissedVersion;
  final String? sha256;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.lastPing,
    this.releaseNotes,
    this.apkUrl,
    this.apkName,
    this.apkLocation,
    this.apkDownloadedAt,
    this.apkSize,
    this.dismissedVersion,
    this.sha256,
  });

  /// Maximum time a downloaded APK file is kept before requiring re-verification/download.
  static const Duration apkTtl = Duration(days: 2);

  /// Whether a newer version is available compared to the currently running version.
  bool get hasUpdate => compareSemver(latestVersion, currentVersion) > 0;

  /// Whether this release includes an APK that can be downloaded on this device.
  bool get hasCompatibleApk => apkUrl != null && apkUrl!.trim().isNotEmpty;

  /// Whether the user has dismissed the notice for this specific latest version.
  bool get isDismissed =>
      dismissedVersion != null &&
      compareSemver(dismissedVersion!, latestVersion) >= 0;

  /// Whether the cached APK file exists on disk and has not exceeded its 2-day TTL.
  bool get isCachedApkValid {
    if (apkLocation == null || apkDownloadedAt == null) return false;
    final age = DateTime.now().difference(apkDownloadedAt!);
    if (age > apkTtl) return false;
    final file = File(apkLocation!);
    if (!file.existsSync()) return false;
    if (apkSize != null && apkSize! > 0 && file.lengthSync() != apkSize) {
      return false;
    }
    return true;
  }

  AppUpdateInfo copyWith({
    String? currentVersion,
    String? latestVersion,
    DateTime? lastPing,
    String? releaseNotes,
    String? apkUrl,
    String? apkName,
    String? apkLocation,
    DateTime? apkDownloadedAt,
    int? apkSize,
    String? dismissedVersion,
    String? sha256,
    bool clearCachedApk = false,
    bool clearDismissedVersion = false,
  }) {
    return AppUpdateInfo(
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      lastPing: lastPing ?? this.lastPing,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      apkUrl: clearCachedApk ? null : apkUrl ?? this.apkUrl,
      apkName: clearCachedApk ? null : apkName ?? this.apkName,
      apkLocation: clearCachedApk ? null : apkLocation ?? this.apkLocation,
      apkDownloadedAt: clearCachedApk
          ? null
          : apkDownloadedAt ?? this.apkDownloadedAt,
      apkSize: clearCachedApk ? null : apkSize ?? this.apkSize,
      dismissedVersion: clearDismissedVersion
          ? null
          : dismissedVersion ?? this.dismissedVersion,
      sha256: clearCachedApk ? null : sha256 ?? this.sha256,
    );
  }

  Map<String, dynamic> toJson() => {
    'current_version': currentVersion,
    'latest_version': latestVersion,
    'last_ping': lastPing.millisecondsSinceEpoch,
    if (releaseNotes != null) 'release_notes': releaseNotes,
    if (apkUrl != null) 'apk_url': apkUrl,
    if (apkName != null) 'apk_name': apkName,
    if (apkLocation != null) 'apk_location': apkLocation,
    if (apkDownloadedAt != null)
      'apk_downloaded_at': apkDownloadedAt!.millisecondsSinceEpoch,
    if (apkSize != null) 'apk_size': apkSize,
    if (dismissedVersion != null) 'dismissed_version': dismissedVersion,
    if (sha256 != null) 'sha256': sha256,
  };

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      currentVersion: json['current_version'] as String? ?? '0.0.0',
      latestVersion: json['latest_version'] as String? ?? '0.0.0',
      lastPing: DateTime.fromMillisecondsSinceEpoch(
        json['last_ping'] as int? ?? 0,
      ),
      releaseNotes: json['release_notes'] as String?,
      apkUrl: json['apk_url'] as String?,
      apkName: json['apk_name'] as String?,
      apkLocation: json['apk_location'] as String?,
      apkDownloadedAt: json['apk_downloaded_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              json['apk_downloaded_at'] as int,
            )
          : null,
      apkSize: json['apk_size'] as int?,
      dismissedVersion: json['dismissed_version'] as String?,
      sha256: json['sha256'] as String?,
    );
  }

  /// Compares two semver strings (e.g. "v0.6.1" vs "0.6.0").
  /// Returns 1 if [a] > [b], -1 if [a] < [b], 0 if equal.
  static int compareSemver(String a, String b) {
    final cleanA = a.replaceFirst(RegExp(r'^[vV]'), '').trim();
    final cleanB = b.replaceFirst(RegExp(r'^[vV]'), '').trim();

    final partsA = cleanA
        .split('.')
        .map((p) => int.tryParse(p.split(RegExp(r'[-+]')).first) ?? 0)
        .toList();
    final partsB = cleanB
        .split('.')
        .map((p) => int.tryParse(p.split(RegExp(r'[-+]')).first) ?? 0)
        .toList();

    for (var i = 0; i < 3; i++) {
      final valA = i < partsA.length ? partsA[i] : 0;
      final valB = i < partsB.length ? partsB[i] : 0;
      if (valA != valB) return valA.compareTo(valB);
    }
    return 0;
  }
}
