import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/models/llm_provider.dart';
import 'package:errand/models/model_option.dart';
import 'package:errand/services/app_settings.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/secret_store.dart';
import 'package:errand/widgets/settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Provider and Model Selection UX', () {
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

    test('persists user selected model across sessions without defaulting to gpt-4o', () async {
      await settings.ensureLoaded();
      expect(settings.selectedModel, kDefaultModelId);

      // User selects a specific model X (e.g. from NVIDIA or OpenRouter)
      const customModel = 'meta/llama-3.3-70b-instruct';
      await settings.setSelectedModel(customModel);
      expect(settings.selectedModel, customModel);

      // Simulate new app session: fresh service instance reading from same database
      final newSessionSettings = AppSettingsService(
        database: db,
        secretStore: SecretStore.instance
          ..debugWithKey(List<int>.generate(32, (i) => i)),
      );
      await newSessionSettings.ensureLoaded();

      // The selected model X must persist as default
      expect(newSessionSettings.selectedModel, customModel);
    });

    test('migrates legacy opencode_zen to nvidia and drops legacy byok preset', () async {
      // Seed database with legacy provider json containing opencode_zen and byok
      final legacyJson = '''
      [
        {"id": "openrouter", "name": "OpenRouter", "baseUrl": "https://openrouter.ai/api/v1", "isDefault": true, "isPreset": true, "customModels": [], "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000"},
        {"id": "opencode_zen", "name": "OpenCode Zen", "baseUrl": "https://opencode.ai/zen/v1", "isDefault": false, "isPreset": true, "customModels": [], "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000"},
        {"id": "groq", "name": "Groq", "baseUrl": "https://api.groq.com/openai/v1", "isDefault": false, "isPreset": true, "customModels": [], "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000"},
        {"id": "byok", "name": "BYOK (Custom)", "baseUrl": "https://api.openai.com/v1", "isDefault": false, "isPreset": true, "customModels": [], "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000"}
      ]
      ''';
      await db.setSetting('app.llm_providers', legacyJson);

      await settings.ensureLoaded();

      final providerIds = settings.providers.map((p) => p.id).toList();
      // Legacy byok preset dropped
      expect(providerIds.contains('byok'), isFalse);
      // Legacy opencode_zen migrated to nvidia
      expect(providerIds.contains('opencode_zen'), isFalse);
      expect(providerIds.contains('nvidia'), isTrue);

      final nvidia = settings.providers.firstWhere((p) => p.id == 'nvidia');
      expect(nvidia.baseUrl, 'https://integrate.api.nvidia.com/v1');
      expect(nvidia.name, 'NVIDIA');
    });

    test('custom provider defaultModels is empty and does not fall back to gpt-4o', () {
      final now = DateTime.now();
      final custom = LlmProvider(
        id: 'custom_local_ollama',
        name: 'Local Ollama',
        baseUrl: 'http://localhost:11434/v1',
        createdAt: now,
        updatedAt: now,
      );

      expect(custom.defaultModels, isEmpty);
      expect(custom.defaultBaseUrl, isEmpty);
    });

    test('NVIDIA preset has correct properties and fallback models', () {
      const preset = ProviderPresetType.nvidia;
      expect(preset.id, 'nvidia');
      expect(preset.displayName, 'NVIDIA');
      expect(preset.defaultBaseUrl, 'https://integrate.api.nvidia.com/v1');
      expect(preset.keyHint, 'nvapi-…');
      expect(preset.fallbackModels, isNotEmpty);
      expect(preset.fallbackModels.any((m) => m.id == 'meta/llama-3.3-70b-instruct'), isTrue);
    });
  });

  testWidgets('Add Provider dialog opens with empty input fields and no preset choices', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProviderFormDialog(),
        ),
      ),
    );
    await tester.pump();

    // Verify dialog title is "Add Provider"
    expect(find.text('Add Provider'), findsOneWidget);

    // Verify preset choice chips are NOT present
    expect(find.text('Select Preset'), findsNothing);
    expect(find.text('OpenCode Zen'), findsNothing);
    expect(find.text('BYOK (Custom)'), findsNothing);

    // Verify text fields exist and are empty
    final textFields = find.byType(TextField);
    expect(textFields, findsNWidgets(3)); // Name, Base URL, API Token / Key

    final nameField = tester.widget<TextField>(textFields.at(0));
    final urlField = tester.widget<TextField>(textFields.at(1));
    final keyField = tester.widget<TextField>(textFields.at(2));

    expect(nameField.controller?.text, isEmpty);
    expect(urlField.controller?.text, isEmpty);
    expect(keyField.controller?.text, isEmpty);
  });
}
