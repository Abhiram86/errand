import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:errand/models/llm_provider.dart';
import 'package:errand/models/model_option.dart';
import 'package:errand/services/model_catalog.dart';
import 'package:errand/widgets/model_picker.dart';

void main() {
  setUp(() {
    ModelCatalogService.clearCache();
  });

  tearDown(() {
    ModelCatalogService.clearCache();
  });

  testWidgets('ModelPicker opens dialog and renders initial options', (tester) async {
    final now = DateTime.now();
    final initialModels = [
      const ModelOption(id: 'model-a', name: 'Model Alpha', provider: 'TestProvider'),
      const ModelOption(id: 'model-b', name: 'Model Beta', provider: 'TestProvider'),
    ];

    final provider = LlmProvider(
      id: 'test-prov',
      name: 'TestProvider',
      baseUrl: 'https://test-prov.invalid/v1',
      apiKey: null,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPicker(
            selectedModel: 'model-a',
            models: initialModels,
            activeProvider: provider,
            providers: [provider],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Model Alpha'), findsOneWidget);

    // Tap to open dialog
    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    expect(find.text('Choose a model'), findsOneWidget);
    expect(find.text('Model Alpha'), findsAtLeastNWidgets(1));
    expect(find.text('Model Beta'), findsOneWidget);
  });

  testWidgets('ModelPicker auto-fetches on open when provider has key and cache is empty', (tester) async {
    final now = DateTime.now();
    final provider = LlmProvider(
      id: 'test-prov-auto',
      name: 'Test Provider Auto',
      baseUrl: 'https://test-prov-auto.invalid/v1',
      apiKey: 'secret-key',
      createdAt: now,
      updatedAt: now,
    );

    final initialModels = [
      const ModelOption(id: 'fallback-auto', name: 'Fallback Auto', provider: 'Test Provider Auto'),
    ];

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'auto-fetched-1', 'name': 'Auto Fetched 1'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPicker(
            selectedModel: 'fallback-auto',
            models: initialModels,
            activeProvider: provider,
            providers: [provider],
            onChanged: (_) {},
            onRefresh: () async {
              await service.load(
                baseUrl: provider.baseUrl,
                apiKey: provider.apiKey ?? '',
                defaultProvider: provider.name,
                forceRefresh: true,
              );
            },
          ),
        ),
      ),
    );

    // Open dialog - triggers auto-refresh via post-frame callback
    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    expect(find.text('Auto Fetched 1'), findsOneWidget);
    service.close();
  });

  testWidgets('ModelPicker refresh button updates dialog options when tapped', (tester) async {
    final now = DateTime.now();
    final provider = LlmProvider(
      id: 'test-prov-btn',
      name: 'Test Provider Btn',
      baseUrl: 'https://test-prov-btn.invalid/v1',
      apiKey: 'secret-key',
      createdAt: now,
      updatedAt: now,
    );

    // Seed initial cache so auto-fetch doesn't trigger on open
    final clientInitial = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'v1-model', 'name': 'V1 Model'},
          ],
        }),
        200,
      );
    });
    final serviceInitial = ModelCatalogService(client: clientInitial);
    await serviceInitial.load(
      baseUrl: provider.baseUrl,
      apiKey: 'secret-key',
      defaultProvider: provider.name,
    );
    serviceInitial.close();

    var refreshCount = 0;
    final clientUpdated = MockClient((request) async {
      refreshCount++;
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'v2-model', 'name': 'V2 Model Updated'},
          ],
        }),
        200,
      );
    });
    final serviceUpdated = ModelCatalogService(client: clientUpdated);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPicker(
            selectedModel: 'v1-model',
            models: const [
              ModelOption(id: 'v1-model', name: 'V1 Model', provider: 'Test Provider Btn'),
            ],
            activeProvider: provider,
            providers: [provider],
            onChanged: (_) {},
            onRefresh: () async {
              await serviceUpdated.load(
                baseUrl: provider.baseUrl,
                apiKey: 'secret-key',
                defaultProvider: provider.name,
                forceRefresh: true,
              );
            },
          ),
        ),
      ),
    );

    // Open dialog
    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    expect(find.text('V1 Model'), findsAtLeastNWidgets(1));
    expect(find.text('V2 Model Updated'), findsNothing);

    // Tap refresh button
    final refreshBtn = find.byTooltip('Refresh catalog');
    expect(refreshBtn, findsOneWidget);
    await tester.tap(refreshBtn);
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
    expect(find.text('V2 Model Updated'), findsOneWidget);

    serviceUpdated.close();
  });

  testWidgets('ModelPicker uses cached models on open if present', (tester) async {
    final now = DateTime.now();
    final provider = LlmProvider(
      id: 'test-prov',
      name: 'Test Provider',
      baseUrl: 'https://test-prov-cached.invalid/v1',
      apiKey: 'secret-key',
      createdAt: now,
      updatedAt: now,
    );

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'pre-cached-model', 'name': 'Pre-Cached Model'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);
    await service.load(
      baseUrl: provider.baseUrl,
      apiKey: 'secret-key',
      defaultProvider: provider.name,
    );

    final fallbackModels = [
      const ModelOption(id: 'fallback-old', name: 'Fallback Old', provider: 'Test Provider'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPicker(
            selectedModel: 'fallback-old',
            models: fallbackModels,
            activeProvider: provider,
            providers: [provider],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    // Open dialog
    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    // Should immediately show the pre-cached model from ModelCatalogService
    expect(find.text('Pre-Cached Model'), findsOneWidget);

    service.close();
  });
}
