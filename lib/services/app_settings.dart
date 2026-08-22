import 'package:meta/meta.dart';

import '../models/model_option.dart';
import 'database.dart';
import 'secret_store.dart';

/// Typed access layer over the app-settings key/value table.
///
/// Secrets ([openRouterKey], [tavilyKey], [baseUrlOverride]) are AES-GCM
/// encrypted via [SecretStore] before they touch SQLite; preferences are
/// stored as plain strings. Values are cached in memory after first read so
/// per-tool-call lookups don't decrypt repeatedly — call [invalidateCache]
/// after writes if another isolate could observe stale values (single-isolate
/// app today, so writes update the cache directly).
final class AppSettingsService {
  /// Production accessor over the real SQLite database.
  static final AppSettingsService instance = AppSettingsService();

  final ErrandDatabase _db;

  /// Tests inject an in-memory [database] and a pre-keyed [secretStore] so
  /// nothing touches the filesystem or the production singletons.
  @visibleForTesting
  AppSettingsService({
    ErrandDatabase? database,
    SecretStore? secretStore,
  })  : _db = database ?? ErrandDatabase.instance,
        _store = secretStore ?? SecretStore.instance;

  final SecretStore _store;

  // -- Keys ----------------------------------------------------------------

  static const _kOpenRouterKey = 'secret.openrouter_api_key';
  static const _kTavilyKey = 'secret.tavily_api_key';
  static const _kBaseUrlOverride = 'secret.base_url_override';
  static const _kSelectedModel = 'pref.selected_model';
  static const _kVoiceLocale = 'pref.voice_input_locale';
  static const _kA11yPromptDismissed = 'pref.a11y_prompt_dismissed';

  String? _openRouterKey;
  String? _tavilyKey;
  String? _baseUrlOverride;
  String? _selectedModel;
  bool _cacheLoaded = false;

  /// Loads all secrets into memory once; safe to call multiple times.
  Future<void> ensureLoaded() async {
    await _store.ensureKey();
    if (_cacheLoaded) return;
    _openRouterKey = await _readSecret(_kOpenRouterKey);
    _tavilyKey = await _readSecret(_kTavilyKey);
    _baseUrlOverride = await _readSecret(_kBaseUrlOverride);
    _cacheLoaded = true;
  }

  /// The OpenRouter API key, or null when not configured.
  String? get openRouterKey => _openRouterKey;

  bool get hasOpenRouterKey =>
      _openRouterKey != null && _openRouterKey!.trim().isNotEmpty;

  Future<void> setOpenRouterKey(String? value) async {
    final trimmed = value?.trim();
    _openRouterKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kOpenRouterKey, _openRouterKey);
  }

  /// The Tavily API key, or null when not configured.
  String? get tavilyKey => _tavilyKey;

  bool get hasTavilyKey => _tavilyKey != null && _tavilyKey!.trim().isNotEmpty;

  Future<void> setTavilyKey(String? value) async {
    final trimmed = value?.trim();
    _tavilyKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kTavilyKey, _tavilyKey);
  }

  /// Optional LLM endpoint override; null/empty → the OpenRouter default.
  String? get baseUrlOverride {
    final value = _baseUrlOverride;
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  Future<void> setBaseUrlOverride(String? value) async {
    final trimmed = value?.trim();
    _baseUrlOverride = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kBaseUrlOverride, _baseUrlOverride);
  }

  /// Base URL for LLM + model-catalog requests.
  static const defaultBaseUrl = 'https://openrouter.ai/api/v1';

  String get effectiveBaseUrl =>
      baseUrlOverride ?? defaultBaseUrl;

  // -- Preferences ----------------------------------------------------------

  /// Last model picked by the user, so launches stop resetting to the
  /// built-in default.
  String get selectedModel => _selectedModel ?? kDefaultModelId;

  Future<void> setSelectedModel(String value) async {
    _selectedModel = value;
    await _db.setSetting(_kSelectedModel, value);
  }

  Future<String?> loadSelectedModel() async {
    _selectedModel = await _db.getSetting(_kSelectedModel);
    return _selectedModel;
  }

  /// Speech-recognition locale id persisted across sessions (null = device
  /// default / not yet picked).
  Future<String?> loadVoiceLocaleId() => _db.getSetting(_kVoiceLocale);

  Future<void> saveVoiceLocaleId(String? localeId) async {
    if (localeId == null || localeId.isEmpty) {
      await _db.deleteSetting(_kVoiceLocale);
    } else {
      await _db.setSetting(_kVoiceLocale, localeId);
    }
  }

  /// "Don't ask again" flag for the accessibility-service prompt.
  Future<bool> a11yPromptDismissed() async =>
      (await _db.getSetting(_kA11yPromptDismissed)) == '1';

  Future<void> setA11yPromptDismissed(bool dismissed) async {
    if (!dismissed) {
      await _db.deleteSetting(_kA11yPromptDismissed);
    } else {
      await _db.setSetting(_kA11yPromptDismissed, '1');
    }
  }

  /// Drops cached secret values (e.g. after tests or key rotation).
  void invalidateCache() {
    _openRouterKey = null;
    _tavilyKey = null;
    _baseUrlOverride = null;
    _cacheLoaded = false;
  }

  // -- Internals -------------------------------------------------------------

  Future<String?> _readSecret(String key) async {
    final token = await _db.getSetting(key);
    if (token == null || token.isEmpty) return null;
    try {
      return await _store.decryptString(token);
    } on SecretStoreException {
      // Key rotated or payload corrupted: treat as unset rather than crash.
      return null;
    }
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.trim().isEmpty) {
      await _db.deleteSetting(key);
      return;
    }
    final token = await _store.encryptString(value.trim());
    await _db.setSetting(key, token);
  }
}
