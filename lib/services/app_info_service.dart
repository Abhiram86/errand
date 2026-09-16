import 'package:flutter/services.dart';

/// Platform app metadata and APK installation service.
class AppInfoService {
  static const MethodChannel _channel = MethodChannel('app_info');

  /// Production singleton instance.
  static final AppInfoService instance = AppInfoService();

  /// Returns the current app version name from Android package info (e.g. "0.6.0").
  Future<String?> getVersion() async {
    try {
      return await _channel.invokeMethod<String>('getVersion');
    } catch (_) {
      return null;
    }
  }

  /// Returns structured device and app info (version, package name, ABI, installer).
  Future<AppPlatformInfo> getAppInfo() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getAppInfo');
      if (res != null) {
        return AppPlatformInfo(
          versionName: res['versionName'] as String? ?? '0.0.0',
          packageName: res['packageName'] as String? ?? 'com.errand.errand',
          abi: res['abi'] as String? ?? 'arm64-v8a',
          installerPackage: res['installerPackage'] as String?,
        );
      }
    } catch (_) {}
    return const AppPlatformInfo(
      versionName: '0.0.0',
      packageName: 'com.errand.errand',
      abi: 'arm64-v8a',
    );
  }

  /// Launches the Android system package installer to install the APK at [filePath].
  Future<bool> installApk(String filePath) async {
    try {
      final res = await _channel.invokeMethod<bool>('installApk', {
        'filePath': filePath,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}

class AppPlatformInfo {
  final String versionName;
  final String packageName;
  final String abi;
  final String? installerPackage;

  const AppPlatformInfo({
    required this.versionName,
    required this.packageName,
    required this.abi,
    this.installerPackage,
  });

  /// Whether this build is the Lite flavor (determined by package ID suffix).
  bool get isLite => packageName.endsWith('.lite');

  /// The flavor name ("lite" or "full").
  String get flavor => isLite ? 'lite' : 'full';
}
