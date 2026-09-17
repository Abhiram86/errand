import 'package:flutter_test/flutter_test.dart';
import 'package:errand/models/llm_provider.dart';
import 'package:errand/services/app_settings.dart';
import 'package:errand/services/database.dart';
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

  test('initializes with the 3 default presets: OpenRouter, NVIDIA, Groq', () async {
    await settings.ensureLoaded();

    expect(settings.providers.length, 3);
    final ids = settings.providers.map((p) => p.id).toList();
    expect(ids, containsAll(['openrouter', 'nvidia', 'groq']));
  });

  test('saves API key encrypted per provider and marks configured', () async {
    await settings.ensureLoaded();

    final nvidia = settings.providers.firstWhere((p) => p.id == 'nvidia');
    expect(nvidia.hasKey, isFalse);

    await settings.saveProvider(nvidia, apiKey: 'nvapi-secret-token');

    expect(settings.providers.firstWhere((p) => p.id == 'nvidia').hasKey, isTrue);

    // Verify raw database row does not have plaintext
    final rawRow = await db.getSetting('secret.provider.nvidia.api_key');
    expect(rawRow, isNotNull);
    expect(rawRow, isNot(contains('nvapi-secret-token')));

    // Verify fresh reload decrypts successfully
    final reloaded = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
    await reloaded.ensureLoaded();

    final reloadedNvidia = reloaded.providers.firstWhere((p) => p.id == 'nvidia');
    expect(reloadedNvidia.apiKey, 'nvapi-secret-token');
  });

  test('can switch active provider', () async {
    await settings.ensureLoaded();

    await settings.setActiveProvider('groq');
    expect(settings.activeProviderId, 'groq');
    expect(settings.activeProvider.name, 'Groq');
    expect(settings.effectiveBaseUrl, 'https://api.groq.com/openai/v1');

    // Reload from database and verify persisted active provider
    final reloaded = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
    await reloaded.ensureLoaded();
    expect(reloaded.activeProviderId, 'groq');
  });

  test('can add custom provider and delete provider with fallback', () async {
    await settings.ensureLoaded();

    final now = DateTime.now();
    final custom = LlmProvider(
      id: 'custom_ollama',
      name: 'Ollama Local',
      baseUrl: 'http://localhost:11434/v1',
      createdAt: now,
      updatedAt: now,
    );

    await settings.saveProvider(custom, apiKey: 'optional-ollama-key');
    expect(settings.providers.any((p) => p.id == 'custom_ollama'), isTrue);

    await settings.setActiveProvider('custom_ollama');
    expect(settings.activeProviderId, 'custom_ollama');

    // Delete custom provider: should fall back to another provider
    await settings.deleteProvider('custom_ollama');
    expect(settings.providers.any((p) => p.id == 'custom_ollama'), isFalse);
    expect(settings.activeProviderId, isNot('custom_ollama'));
    expect(await db.getSetting('secret.provider.custom_ollama.api_key'), isNull);
  });

  test('can unset or clear provider API key', () async {
    await settings.ensureLoaded();

    final groq = settings.providers.firstWhere((p) => p.id == 'groq');
    await settings.saveProvider(groq, apiKey: 'gsk_test123');
    expect(settings.providers.firstWhere((p) => p.id == 'groq').hasKey, isTrue);

    // Now clear the key
    await settings.saveProvider(groq, apiKey: '', clearKey: true);
    final clearedGroq = settings.providers.firstWhere((p) => p.id == 'groq');
    expect(clearedGroq.hasKey, isFalse);
    expect(clearedGroq.apiKey, isNull);
    expect(await db.getSetting('secret.provider.groq.api_key'), isNull);
  });

  test('supports adding multiple BYOK custom providers without overwriting', () async {
    await settings.ensureLoaded();

    final now = DateTime.now();
    final byok1 = LlmProvider(
      id: 'byok_1001',
      name: 'Custom Endpoint 1',
      baseUrl: 'https://api.custom1.com/v1',
      createdAt: now,
      updatedAt: now,
    );
    final byok2 = LlmProvider(
      id: 'byok_1002',
      name: 'Custom Endpoint 2',
      baseUrl: 'https://api.custom2.com/v1',
      createdAt: now,
      updatedAt: now,
    );

    await settings.saveProvider(byok1, apiKey: 'key-1');
    await settings.saveProvider(byok2, apiKey: 'key-2');

    expect(settings.providers.any((p) => p.id == 'byok_1001'), isTrue);
    expect(settings.providers.any((p) => p.id == 'byok_1002'), isTrue);
    expect(settings.providers.firstWhere((p) => p.id == 'byok_1001').name, 'Custom Endpoint 1');
    expect(settings.providers.firstWhere((p) => p.id == 'byok_1002').name, 'Custom Endpoint 2');
  });

  test('NVIDIA has correct base URL https://integrate.api.nvidia.com/v1 and default models', () async {
    await settings.ensureLoaded();

    final nvidia = settings.providers.firstWhere((p) => p.id == 'nvidia');
    expect(nvidia.baseUrl, 'https://integrate.api.nvidia.com/v1');
    expect(nvidia.defaultBaseUrl, 'https://integrate.api.nvidia.com/v1');
    expect(nvidia.defaultModels, isNotEmpty);
    expect(nvidia.defaultModels.first.id, 'meta/llama-3.3-70b-instruct');
  });

  test('OpenRouter has openrouter/free router as the first default model', () async {
    await settings.ensureLoaded();

    final openRouter = settings.providers.firstWhere((p) => p.id == 'openrouter');
    expect(openRouter.baseUrl, 'https://openrouter.ai/api/v1');
    expect(openRouter.defaultModels, isNotEmpty);
    expect(openRouter.defaultModels.first.id, 'openrouter/free');
  });

  test('providers with keys appear first, keyless appear later, preserving relative order', () async {
    await settings.ensureLoaded();
    // Initially all 3 presets are keyless
    expect(settings.providers.every((p) => !p.hasKey), isTrue);

    // Add a 4th provider (custom) with an API key
    final now = DateTime.now();
    final byokCustom = LlmProvider(
      id: 'custom_4th',
      name: 'Custom 4th Provider',
      baseUrl: 'https://api.custom.com/v1',
      createdAt: now,
      updatedAt: now,
    );
    await settings.saveProvider(byokCustom, apiKey: 'secret-key-123');

    // Also give Groq a key
    final groq = settings.providers.firstWhere((p) => p.id == 'groq');
    await settings.saveProvider(groq, apiKey: 'gsk_test');

    final ordered = settings.providers;
    expect(ordered.length, 4);
    expect(ordered[0].id, 'groq');
    expect(ordered[1].id, 'custom_4th');
    expect(ordered[0].hasKey, isTrue);
    expect(ordered[1].hasKey, isTrue);
    expect(ordered[2].hasKey, isFalse);
    expect(ordered[3].hasKey, isFalse);
  });

  test('defaultStartupProvider defaults to OpenRouter when no provider is configured', () async {
    await settings.ensureLoaded();
    expect(settings.hasAnyConfiguredProvider, isFalse);
    expect(settings.defaultStartupProvider.id, 'openrouter');
  });

  test('defaultStartupProvider defaults to configured provider when one has key', () async {
    await settings.ensureLoaded();

    final nvidia = settings.providers.firstWhere((p) => p.id == 'nvidia');
    await settings.saveProvider(nvidia, apiKey: 'nvapi-key');

    expect(settings.hasAnyConfiguredProvider, isTrue);
    expect(settings.defaultStartupProvider.id, 'nvidia');
  });

  test('hasSelectedModel accurately reflects cached selection status', () async {
    await settings.ensureLoaded();
    expect(settings.hasSelectedModel, isFalse);

    await settings.setSelectedModel('custom/model-x');
    expect(settings.hasSelectedModel, isTrue);
    expect(settings.selectedModel, 'custom/model-x');
  });
}
