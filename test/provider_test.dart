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

  test('initializes with the 4 default presets: OpenCode Zen, OpenRouter, Groq, BYOK', () async {
    await settings.ensureLoaded();

    expect(settings.providers.length, 4);
    final ids = settings.providers.map((p) => p.id).toList();
    expect(ids, containsAll(['opencode_zen', 'openrouter', 'groq', 'byok']));
  });

  test('saves API key encrypted per provider and marks configured', () async {
    await settings.ensureLoaded();

    final zen = settings.providers.firstWhere((p) => p.id == 'opencode_zen');
    expect(zen.hasKey, isFalse);

    await settings.saveProvider(zen, apiKey: 'zen-secret-token');

    expect(settings.providers.firstWhere((p) => p.id == 'opencode_zen').hasKey, isTrue);

    // Verify raw database row does not have plaintext
    final rawRow = await db.getSetting('secret.provider.opencode_zen.api_key');
    expect(rawRow, isNotNull);
    expect(rawRow, isNot(contains('zen-secret-token')));

    // Verify fresh reload decrypts successfully
    final reloaded = AppSettingsService(
      database: db,
      secretStore: SecretStore.instance
        ..debugWithKey(List<int>.generate(32, (i) => i)),
    );
    await reloaded.ensureLoaded();

    final reloadedZen = reloaded.providers.firstWhere((p) => p.id == 'opencode_zen');
    expect(reloadedZen.apiKey, 'zen-secret-token');
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

  test('OpenCode Zen has correct base URL https://opencode.ai/zen/v1 and default models', () async {
    await settings.ensureLoaded();

    final zen = settings.providers.firstWhere((p) => p.id == 'opencode_zen');
    expect(zen.baseUrl, 'https://opencode.ai/zen/v1');
    expect(zen.defaultBaseUrl, 'https://opencode.ai/zen/v1');
    expect(zen.defaultModels, isNotEmpty);
    expect(zen.defaultModels.first.id, 'nemotron-3.5-lightning-free');
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
    // Initially all 4 presets are keyless
    expect(settings.providers.every((p) => !p.hasKey), isTrue);

    // Add a 5th provider (BYOK custom) with an API key
    final now = DateTime.now();
    final byokCustom = LlmProvider(
      id: 'byok_custom_5th',
      name: 'Custom 5th Provider',
      baseUrl: 'https://api.custom.com/v1',
      createdAt: now,
      updatedAt: now,
    );
    await settings.saveProvider(byokCustom, apiKey: 'secret-key-123');

    // Also give Groq a key
    final groq = settings.providers.firstWhere((p) => p.id == 'groq');
    await settings.saveProvider(groq, apiKey: 'gsk_test');

    final ordered = settings.providers;
    // Groq was earlier in original list than byokCustom, so between keyed providers:
    // Groq (index 0), then byokCustom (index 1).
    // Keyless follow after in original order: OpenRouter, OpenCode Zen, BYOK.
    expect(ordered[0].id, 'groq');
    expect(ordered[1].id, 'byok_custom_5th');
    expect(ordered[0].hasKey, isTrue);
    expect(ordered[1].hasKey, isTrue);
    expect(ordered[2].hasKey, isFalse);
    expect(ordered[3].hasKey, isFalse);
    expect(ordered[4].hasKey, isFalse);
  });
}
