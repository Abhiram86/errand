import 'dart:convert';

import 'package:meta/meta.dart';

import '../models/llm_provider.dart';
import '../models/model_option.dart';
import 'database.dart';
import 'secret_store.dart';

/// Typed access layer over the app-settings key/value table.
///
/// Secrets are AES-GCM encrypted via [SecretStore] before they touch SQLite;
/// preferences are stored as plain strings. Values are cached in memory after
/// first read so per-tool-call lookups don't decrypt repeatedly.
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

  static const _kProviders = 'pref.llm_providers_v1';
  static const _kActiveProviderId = 'pref.active_provider_id';
  static const _secretProviderKeyPrefix = 'secret.provider.';

  String? _openRouterKey;
  String? _tavilyKey;
  String? _baseUrlOverride;
  String? _selectedModel;
  bool _cacheLoaded = false;

  List<LlmProvider> _providers = [];
  String? _activeProviderId;

  /// Loads all secrets and providers into memory once; safe to call multiple times.
  Future<void> ensureLoaded() async {
    await _store.ensureKey();
    if (_cacheLoaded) return;

    _openRouterKey = await _readSecret(_kOpenRouterKey);
    _tavilyKey = await _readSecret(_kTavilyKey);
    _baseUrlOverride = await _readSecret(_kBaseUrlOverride);
    _selectedModel = await _db.getSetting(_kSelectedModel);

    await _loadProviders();
    _cacheLoaded = true;
  }

  bool _providerHasKey(LlmProvider p) {
    if (p.hasKey) return true;
    if (p.id == ProviderPresetType.openRouter.id && hasOpenRouterKey) return true;
    return false;
  }

  List<LlmProvider> get providers {
    final withKeys = <LlmProvider>[];
    final withoutKeys = <LlmProvider>[];
    for (final p in _providers) {
      final resolved = (p.id == ProviderPresetType.openRouter.id && !p.hasKey && hasOpenRouterKey)
          ? p.copyWith(apiKey: openRouterKey)
          : p;
      if (_providerHasKey(resolved)) {
        withKeys.add(resolved);
      } else {
        withoutKeys.add(resolved);
      }
    }
    return List.unmodifiable([...withKeys, ...withoutKeys]);
  }

  String get activeProviderId {
    if (_activeProviderId != null &&
        _providers.any((p) => p.id == _activeProviderId)) {
      return _activeProviderId!;
    }
    return providers.isNotEmpty ? providers.first.id : ProviderPresetType.openRouter.id;
  }

  LlmProvider get activeProvider {
    final id = activeProviderId;
    for (final p in _providers) {
      if (p.id == id) {
        if (p.id == ProviderPresetType.openRouter.id && !p.hasKey && hasOpenRouterKey) {
          return p.copyWith(apiKey: openRouterKey);
        }
        return p;
      }
    }
    if (_providers.isNotEmpty) {
      final first = _providers.first;
      if (first.id == ProviderPresetType.openRouter.id && !first.hasKey && hasOpenRouterKey) {
        return first.copyWith(apiKey: openRouterKey);
      }
      return first;
    }
    return ProviderPresetType.openRouter.createProvider(isDefault: true);
  }

  bool get hasActiveProviderKey => activeProvider.hasKey;

  Future<void> setActiveProvider(String providerId) async {
    if (!_providers.any((p) => p.id == providerId)) return;
    _activeProviderId = providerId;
    await _db.setSetting(_kActiveProviderId, providerId);
    for (var i = 0; i < _providers.length; i++) {
      final p = _providers[i];
      if (p.isDefault != (p.id == providerId)) {
        _providers[i] = p.copyWith(isDefault: p.id == providerId);
      }
    }
    await _saveProvidersMetadata();
  }

  Future<void> saveProvider(
    LlmProvider provider, {
    String? apiKey,
    bool clearKey = false,
  }) async {
    final secretKey = '$_secretProviderKeyPrefix${provider.id}.api_key';
    String? resolvedKey;

    if (clearKey) {
      resolvedKey = null;
      await _writeSecret(secretKey, null);
      if (provider.id == ProviderPresetType.openRouter.id) {
        _openRouterKey = null;
        await _writeSecret(_kOpenRouterKey, null);
      }
    } else if (apiKey != null) {
      final trimmed = apiKey.trim();
      resolvedKey = trimmed.isEmpty ? null : trimmed;
      await _writeSecret(secretKey, resolvedKey);
      if (provider.id == ProviderPresetType.openRouter.id) {
        _openRouterKey = resolvedKey;
        await _writeSecret(_kOpenRouterKey, resolvedKey);
      }
    } else {
      resolvedKey = provider.apiKey;
    }

    final updated = provider.copyWith(
      apiKey: resolvedKey,
      updatedAt: DateTime.now(),
    );

    final index = _providers.indexWhere((p) => p.id == provider.id);
    if (index >= 0) {
      _providers[index] = updated;
    } else {
      _providers.add(updated);
    }

    if (updated.isDefault) {
      _activeProviderId = updated.id;
      await _db.setSetting(_kActiveProviderId, updated.id);
      for (var i = 0; i < _providers.length; i++) {
        if (_providers[i].id != updated.id && _providers[i].isDefault) {
          _providers[i] = _providers[i].copyWith(isDefault: false);
        }
      }
    }

    await _saveProvidersMetadata();
  }

  Future<void> deleteProvider(String providerId) async {
    final secretKey = '$_secretProviderKeyPrefix$providerId.api_key';
    await _writeSecret(secretKey, null);
    if (providerId == ProviderPresetType.openRouter.id) {
      _openRouterKey = null;
      await _writeSecret(_kOpenRouterKey, null);
    }

    _providers.removeWhere((p) => p.id == providerId);

    if (_providers.isEmpty) {
      // Re-initialize default presets so user is never left with zero providers
      _providers = _createDefaultPresets();
      _activeProviderId = _providers.first.id;
    } else if (_activeProviderId == providerId) {
      _activeProviderId = _providers.first.id;
      _providers[0] = _providers[0].copyWith(isDefault: true);
      await _db.setSetting(_kActiveProviderId, _activeProviderId!);
    }

    await _saveProvidersMetadata();
  }

  Future<void> _loadProviders() async {
    final rawJson = await _db.getSetting(_kProviders);
    _activeProviderId = await _db.getSetting(_kActiveProviderId);

    if (rawJson == null || rawJson.trim().isEmpty) {
      // Initialize the default presets: OpenRouter, NVIDIA, Groq
      _providers = _createDefaultPresets();

      // If legacy OpenRouter key or base URL override existed, migrate it
      if (_openRouterKey != null && _openRouterKey!.isNotEmpty) {
        final openRouterIndex = _providers.indexWhere(
          (p) => p.id == ProviderPresetType.openRouter.id,
        );
        if (openRouterIndex >= 0) {
          _providers[openRouterIndex] = _providers[openRouterIndex].copyWith(
            apiKey: _openRouterKey,
            baseUrl: _baseUrlOverride ?? ProviderPresetType.openRouter.defaultBaseUrl,
            isDefault: true,
          );
          _activeProviderId = ProviderPresetType.openRouter.id;
        }
      }

      _activeProviderId ??= _providers.first.id;
      await _saveProvidersMetadata();
      await _db.setSetting(_kActiveProviderId, _activeProviderId!);
      return;
    }

    try {
      final decoded = jsonDecode(rawJson) as List<dynamic>;
      final list = <LlmProvider>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        var p = LlmProvider.fromJson(item);
        // Remove legacy BYOK preset (custom providers are added via Add button)
        if (p.id == 'byok' && p.isPreset) {
          continue;
        }
        // Migrate legacy OpenCode Zen to NVIDIA preset
        if (p.id == 'opencode_zen' || p.id == 'opencode') {
          p = ProviderPresetType.nvidia.createProvider(
            isDefault: p.isDefault,
          );
        }
        final secretKey = '$_secretProviderKeyPrefix${p.id}.api_key';
        var key = await _readSecret(secretKey);
        // Fallback for openrouter legacy key
        if (p.id == ProviderPresetType.openRouter.id && (key == null || key.isEmpty)) {
          key = _openRouterKey;
        }
        list.add(p.copyWith(apiKey: key));
      }

      // Ensure standard presets exist
      for (final preset in ProviderPresetType.values) {
        if (!list.any((p) => p.id == preset.id)) {
          list.add(preset.createProvider());
        }
      }

      if (list.isEmpty) {
        _providers = _createDefaultPresets();
      } else {
        _providers = list;
      }
    } catch (_) {
      _providers = _createDefaultPresets();
    }

    if (_activeProviderId == null ||
        !_providers.any((p) => p.id == _activeProviderId)) {
      _activeProviderId = _providers.first.id;
      await _db.setSetting(_kActiveProviderId, _activeProviderId!);
    }
  }

  Future<void> _saveProvidersMetadata() async {
    final serialized = jsonEncode(_providers.map((p) => p.toJson()).toList());
    await _db.setSetting(_kProviders, serialized);
  }

  List<LlmProvider> _createDefaultPresets() {
    return [
      ProviderPresetType.openRouter.createProvider(isDefault: true),
      ProviderPresetType.nvidia.createProvider(),
      ProviderPresetType.groq.createProvider(),
    ];
  }

  // -- Legacy & Convenience Accessors ----------------------------------------

  /// The OpenRouter API key, or null when not configured.
  String? get openRouterKey {
    final orProvider = _providers.cast<LlmProvider?>().firstWhere(
          (p) => p?.id == ProviderPresetType.openRouter.id,
          orElse: () => null,
        );
    return orProvider?.apiKey ?? _openRouterKey;
  }

  bool get hasOpenRouterKey =>
      openRouterKey != null && openRouterKey!.trim().isNotEmpty;

  Future<void> setOpenRouterKey(String? value) async {
    final trimmed = value?.trim();
    _openRouterKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kOpenRouterKey, _openRouterKey);
    final orProvider = _providers.cast<LlmProvider?>().firstWhere(
          (p) => p?.id == ProviderPresetType.openRouter.id,
          orElse: () => null,
        );
    if (orProvider != null) {
      await saveProvider(orProvider, apiKey: _openRouterKey);
    }
  }

  /// The Tavily API key, or null when not configured.
  String? get tavilyKey => _tavilyKey;

  bool get hasTavilyKey => _tavilyKey != null && _tavilyKey!.trim().isNotEmpty;

  Future<void> setTavilyKey(String? value) async {
    final trimmed = value?.trim();
    _tavilyKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kTavilyKey, _tavilyKey);
  }

  /// Base URL override for active provider or legacy OpenRouter.
  String? get baseUrlOverride {
    final value = _baseUrlOverride;
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  Future<void> setBaseUrlOverride(String? value) async {
    final trimmed = value?.trim();
    _baseUrlOverride = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _writeSecret(_kBaseUrlOverride, _baseUrlOverride);
  }

  /// Default OpenRouter base URL.
  static const defaultBaseUrl = 'https://openrouter.ai/api/v1';

  String get effectiveBaseUrl =>
      baseUrlOverride ??
      (activeProvider.baseUrl.isNotEmpty ? activeProvider.baseUrl : defaultBaseUrl);

  // -- Preferences ----------------------------------------------------------

  /// Last model picked by the user.
  String get selectedModel => _selectedModel ?? kDefaultModelId;

  Future<void> setSelectedModel(String value) async {
    _selectedModel = value;
    await _db.setSetting(_kSelectedModel, value);
  }

  Future<String?> loadSelectedModel() async {
    _selectedModel = await _db.getSetting(_kSelectedModel);
    return _selectedModel;
  }

  /// Speech-recognition locale id persisted across sessions.
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
    _providers = [];
    _activeProviderId = null;
    _cacheLoaded = false;
  }

  // -- Internals -------------------------------------------------------------

  Future<String?> _readSecret(String key) async {
    final token = await _db.getSetting(key);
    if (token == null || token.isEmpty) return null;
    try {
      return await _store.decryptString(token);
    } on SecretStoreException {
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
