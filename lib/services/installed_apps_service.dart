import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'database.dart';
import 'intent_service.dart';

class InstalledApp {
  final String package;
  final String label;

  const InstalledApp({required this.package, required this.label});

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
        package: json['package'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );

  Map<String, String> toJson() => {'package': package, 'label': label};

  @override
  String toString() => '$label ($package)';
}

const Map<String, String> _commonKnownPackages = {
  'com.google.android.youtube': 'YouTube',
  'com.google.android.apps.youtube.music': 'YT Music',
  'com.spotify.music': 'Spotify',
  'com.bt.bms': 'BookMyShow',
  'com.whatsapp': 'WhatsApp',
  'org.telegram.messenger': 'Telegram',
  'com.instagram.android': 'Instagram',
  'com.google.android.apps.maps': 'Maps',
  'com.google.android.gm': 'Gmail',
  'com.google.android.calendar': 'Calendar',
  'com.google.android.apps.photos': 'Photos',
  'com.google.android.deskclock': 'Clock',
  'com.google.android.calculator': 'Calculator',
  'com.android.calculator2': 'Calculator',
  'com.android.chrome': 'Chrome',
  'com.android.settings': 'Settings',
  'com.twitter.android': 'X',
  'com.x.android': 'X',
  'com.facebook.katana': 'Facebook',
  'com.netflix.mediaclient': 'Netflix',
  'com.slack': 'Slack',
  'com.discord': 'Discord',
  'com.reddit.frontpage': 'Reddit',
  'in.swiggy.android': 'Swiggy',
  'com.application.zomato': 'Zomato',
  'com.ubercab': 'Uber',
  'com.olacabs.customer': 'Ola',
  'com.phonepe.app': 'PhonePe',
  'net.one97.paytm': 'Paytm',
  'com.google.android.apps.nbu.paisa.user': 'Google Pay',
  'com.amazon.mShop.android.shopping': 'Amazon',
  'com.flipkart.android': 'Flipkart',
  'org.mozilla.firefox': 'Firefox',
};

class InstalledAppsService {
  static final InstalledAppsService instance = InstalledAppsService();

  static const String _kCacheKey = 'cache.installed_apps';

  final List<InstalledApp> _apps = [];
  final Map<String, String> _labelByPackage = {};
  bool _initialized = false;

  List<InstalledApp> get apps => List.unmodifiable(_apps);

  @visibleForTesting
  void setAppsForTesting(List<InstalledApp> testApps) {
    _apps.clear();
    _labelByPackage.clear();
    for (final a in testApps) {
      if (a.package.isNotEmpty) {
        _apps.add(a);
        _labelByPackage[a.package] = a.label;
      }
    }
    _initialized = true;
  }

  /// Loads cached apps from database on startup, then queries native package manager in background.
  Future<void> initAndRefresh({IntentService? service, ErrandDatabase? db}) async {
    if (!_initialized) {
      await loadFromCache(db: db);
    }
    await refresh(service: service, db: db);
  }

  Future<void> loadFromCache({ErrandDatabase? db}) async {
    try {
      final database = db ?? ErrandDatabase.instance;
      final cachedJson = await database.getSetting(_kCacheKey);
      if (cachedJson != null && cachedJson.isNotEmpty) {
        final decoded = jsonDecode(cachedJson) as List<dynamic>;
        _apps.clear();
        _labelByPackage.clear();
        for (final item in decoded) {
          if (item is Map) {
            final app = InstalledApp.fromJson(Map<String, dynamic>.from(item));
            if (app.package.isNotEmpty) {
              _apps.add(app);
              _labelByPackage[app.package] = app.label;
            }
          }
        }
      }
    } catch (_) {}
    _initialized = true;
  }

  /// Queries the platform channel for installed launcher applications and persists to cache.
  Future<void> refresh({IntentService? service, ErrandDatabase? db}) async {
    try {
      final svc = service ?? IntentService();
      final fresh = await svc.getInstalledApps();
      if (fresh.isEmpty) return;

      _apps.clear();
      _labelByPackage.clear();
      for (final item in fresh) {
        final pkg = item['package'] ?? '';
        final lbl = item['label'] ?? pkg;
        if (pkg.isNotEmpty) {
          final app = InstalledApp(package: pkg, label: lbl);
          _apps.add(app);
          _labelByPackage[pkg] = lbl;
        }
      }
      _initialized = true;

      final database = db ?? ErrandDatabase.instance;
      final serialized = jsonEncode(_apps.map((a) => a.toJson()).toList());
      await database.setSetting(_kCacheKey, serialized);
    } catch (_) {}
  }

  /// Returns the human-readable display name for [package].
  /// Checks on-device cache, then known popular packages, and falls back to clean name parsing.
  String getLabel(String package) {
    if (package.isEmpty) return 'app';
    final cached = _labelByPackage[package];
    if (cached != null && cached.isNotEmpty) return cached;

    final known = _commonKnownPackages[package];
    if (known != null) return known;

    return cleanPackageName(package);
  }

  /// Heuristic to format a package name like 'com.spotify.music' into 'Spotify'.
  static String cleanPackageName(String package) {
    final segments = package
        .split('.')
        .where((s) => s.isNotEmpty && !const {'com', 'org', 'net', 'io', 'android', 'google', 'apps', 'app', 'in'}.contains(s.toLowerCase()))
        .toList();

    if (segments.isEmpty) {
      final last = package.split('.').lastWhere((s) => s.isNotEmpty, orElse: () => package);
      return _capitalize(last);
    }

    final chosen = segments.first;
    return _capitalize(chosen);
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Checks if [query] exactly matches an installed package or app label (case-insensitive).
  InstalledApp? findExact(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;

    final normalizedQ = _normalize(q);

    // 1. Direct package match
    for (final app in _apps) {
      if (app.package.toLowerCase() == q) return app;
    }

    // 2. Direct label match
    for (final app in _apps) {
      if (app.label.toLowerCase() == q) return app;
    }

    // 3. Normalized label match (e.g. 'ytmusic' == 'yt music')
    for (final app in _apps) {
      if (_normalize(app.label) == normalizedQ) return app;
    }

    // 4. Known packages map
    if (_commonKnownPackages.containsKey(q)) {
      return InstalledApp(package: q, label: _commonKnownPackages[q]!);
    }
    for (final entry in _commonKnownPackages.entries) {
      if (_normalize(entry.value) == normalizedQ) {
        return InstalledApp(package: entry.key, label: entry.value);
      }
    }

    return null;
  }

  /// Returns the top [limit] matching installed apps for a search [query].
  List<InstalledApp> findBestMatches(String query, {int limit = 10}) {
    final rawQ = query.trim().toLowerCase();
    if (rawQ.isEmpty) {
      return _apps.take(limit).toList();
    }

    // Strip common package prefixes if someone typed 'com.bookmyshow'
    var cleanQ = rawQ;
    if (cleanQ.contains('.')) {
      final parts = cleanQ.split('.').where((p) => !const {'com', 'org', 'net', 'android', 'google', 'apps', 'in'}.contains(p)).toList();
      if (parts.isNotEmpty) {
        cleanQ = parts.join(' ');
      }
    }

    final normQuery = _normalize(cleanQ);
    final queryWords = cleanQ.split(RegExp(r'[\s_.-]+')).where((w) => w.isNotEmpty).toList();

    final scored = <MapEntry<InstalledApp, int>>[];

    for (final app in _apps) {
      final normLabel = _normalize(app.label);
      final normPkg = _normalize(app.package);
      final labelLower = app.label.toLowerCase();
      final pkgLower = app.package.toLowerCase();

      int score = 0;

      if (normLabel == normQuery) {
        score = 100;
      } else if (normPkg == normQuery) {
        score = 95;
      } else if (normLabel.startsWith(normQuery)) {
        score = 85;
      } else if (normLabel.contains(normQuery)) {
        score = 75;
      } else if (normPkg.contains(normQuery)) {
        score = 65;
      } else {
        // Word matches (e.g. query "music" matches "YT Music")
        int wordMatches = 0;
        for (final qw in queryWords) {
          if (labelLower.contains(qw) || pkgLower.contains(qw)) {
            wordMatches++;
          }
        }
        if (wordMatches > 0) {
          score = 50 + (wordMatches * 10);
        } else if (_isSubsequence(normQuery, normLabel)) {
          score = 35;
        }
      }

      if (score > 0) {
        scored.add(MapEntry(app, score));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).take(limit).toList();
  }

  static String _normalize(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static bool _isSubsequence(String sub, String target) {
    if (sub.isEmpty) return true;
    if (target.isEmpty) return false;
    int i = 0;
    int j = 0;
    while (i < sub.length && j < target.length) {
      if (sub[i] == target[j]) {
        i++;
      }
      j++;
    }
    return i == sub.length;
  }
}
