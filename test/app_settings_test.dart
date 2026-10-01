import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:errand/models/llm_provider.dart';
import 'package:errand/models/model_option.dart';
import 'package:errand/services/app_settings.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/model_catalog.dart';
import 'package:errand/services/secret_store.dart';

void main() {
  late ErrandDatabase db;
  late AppSettingsService settings;

  setUp(() {
    db = ErrandDatabase.inMemory();
    settings = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
  });

  tearDown(() => db.close());

  test('secrets round-trip through SQLite encrypted', () async {
    await settings.setOpenRouterKey('sk-or-v1-secret');
    await settings.setTavilyKey('tvly-secret');

    // Cache is warm after write — but verify against a fresh instance over
    // the same DB so we know it really persisted (encrypted).
    final reloaded = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
    await reloaded.ensureLoaded();

    expect(reloaded.openRouterKey, 'sk-or-v1-secret');
    expect(reloaded.tavilyKey, 'tvly-secret');
    expect(reloaded.hasOpenRouterKey, isTrue);
    expect(reloaded.hasTavilyKey, isTrue);
  });

  test('stored value in the raw table is NOT plaintext', () async {
    await settings.setOpenRouterKey('sk-or-v1-plaintext-check');
    final row = await db.getSetting('secret.openrouter_api_key');
    expect(row, isNotNull);
    expect(row, isNot(contains('sk-or-v1-plaintext-check')));
  });

  test('clearing a key removes it', () async {
    await settings.setTavilyKey('tvly-123');
    await settings.setTavilyKey(null);
    expect(settings.tavilyKey, isNull);
    expect(settings.hasTavilyKey, isFalse);
  });

  test('whitespace-only values are treated as unset', () async {
    await settings.setBaseUrlOverride('   ');
    expect(settings.baseUrlOverride, isNull);
    expect(settings.effectiveBaseUrl, AppSettingsService.defaultBaseUrl);
  });

  test('base URL override changes effective URL', () async {
    await settings.setBaseUrlOverride('https://my-proxy.example.com/v1');
    expect(
      settings.effectiveBaseUrl,
      'https://my-proxy.example.com/v1',
    );
    await settings.setBaseUrlOverride(null);
    expect(settings.effectiveBaseUrl, AppSettingsService.defaultBaseUrl);
  });

  test('selected model persists and defaults', () async {
    expect(settings.selectedModel, equals(kDefaultModelId));
    await settings.setSelectedModel('openai/gpt-4o-mini');

    final reloaded = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
    await reloaded.loadSelectedModel();
    expect(reloaded.selectedModel, 'openai/gpt-4o-mini');
  });

  test('voice locale and a11y flag persist as plain preferences', () async {
    await settings.saveVoiceLocaleId('en-US');
    expect(await settings.loadVoiceLocaleId(), 'en-US');
    await settings.saveVoiceLocaleId(null);
    expect(await settings.loadVoiceLocaleId(), isNull);

    expect(await settings.a11yPromptDismissed(), isFalse);
    await settings.setA11yPromptDismissed(true);
    expect(await settings.a11yPromptDismissed(), isTrue);
    await settings.setA11yPromptDismissed(false);
    expect(await settings.a11yPromptDismissed(), isFalse);
  });

  test('isLoaded is false before ensureLoaded and true after, whenLoaded resolves', () async {
    final fresh = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );

    expect(fresh.isLoaded, isFalse);

    bool resolved = false;
    final future = fresh.whenLoaded.then((_) => resolved = true);
    expect(resolved, isFalse);

    await future;
    expect(resolved, isTrue);
    expect(fresh.isLoaded, isTrue);

    // Subsequent awaits on whenLoaded return immediately
    bool subsequentResolved = false;
    await fresh.whenLoaded.then((_) => subsequentResolved = true);
    expect(subsequentResolved, isTrue);
  });

  test('concurrent whenLoaded callers join a single load', () async {
    final fresh = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );

    var resolved = 0;
    await Future.wait([
      fresh.whenLoaded.then((_) => resolved++),
      fresh.whenLoaded.then((_) => resolved++),
      fresh.whenLoaded.then((_) => resolved++),
    ]);
    expect(resolved, equals(3));
    expect(fresh.isLoaded, isTrue);
  });

  test('rotating a provider key invalidates the model catalog (R2-X2)', () async {
    // Readers call getCachedModels(baseUrl) without a key and resolve through
    // the unscoped alias, so a rotated key would be served the previous key's
    // catalog unless the write path invalidates. Seed the static cache under
    // the old key, rotate via saveProvider, and assert the alias is gone (the
    // next read refetches instead of serving stale models).
    const baseUrl = 'https://x2-rotation-test.invalid/api/v1/';
    ModelCatalogService.clearCache();
    try {
      final catalog = ModelCatalogService(
        client: MockClient((request) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 'test/old-model', 'name': 'Old Model'},
            ],
          }),
          200,
        )),
      );
      await catalog.load(baseUrl: baseUrl, apiKey: 'old-key');
      catalog.close();
      expect(
        ModelCatalogService.getCachedModels(baseUrl),
        isNotNull,
        reason: 'seeded catalog must resolve through the unscoped alias',
      );

      final now = DateTime.now();
      final provider = LlmProvider(
        id: 'x2-provider',
        name: 'X2',
        baseUrl: baseUrl,
        apiKey: 'old-key',
        createdAt: now,
        updatedAt: now,
      );
      await settings.saveProvider(provider, apiKey: 'new-key');
      expect(
        ModelCatalogService.getCachedModels(baseUrl),
        isNull,
        reason: 'key rotation must invalidate the catalog',
      );

      // Same-key saves must NOT invalidate: re-seed, save the identical key,
      // and assert the cache survives.
      final catalog2 = ModelCatalogService(
        client: MockClient((request) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 'test/old-model', 'name': 'Old Model'},
            ],
          }),
          200,
        )),
      );
      await catalog2.load(baseUrl: baseUrl, apiKey: 'new-key');
      catalog2.close();
      final rotated = LlmProvider(
        id: 'x2-provider',
        name: 'X2',
        baseUrl: baseUrl,
        apiKey: 'new-key',
        createdAt: now,
        updatedAt: now,
      );
      await settings.saveProvider(rotated, apiKey: 'new-key');
      expect(
        ModelCatalogService.getCachedModels(baseUrl),
        isNotNull,
        reason: 'unchanged key must keep the cache',
      );

      // Wiping the key invalidates too: entries fetched under the old key must
      // not be served to keyless readers.
      await settings.saveProvider(rotated, clearKey: true);
      expect(
        ModelCatalogService.getCachedModels(baseUrl),
        isNull,
        reason: 'clearing the key must invalidate the catalog',
      );
    } finally {
      ModelCatalogService.clearCache();
    }
  });
}
