import 'package:flutter_test/flutter_test.dart';
import 'package:errand/models/model_option.dart';
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
}
