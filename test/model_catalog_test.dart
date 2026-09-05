import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:errand/services/model_catalog.dart';

void main() {
  test('loads text models and caches the catalog per base URL', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      expect(request.url.queryParameters['output_modalities'], 'text');
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'openai/gpt-4o-mini', 'name': 'GPT-4o mini'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    final first = await service.load(
      baseUrl: 'https://catalog-cache-test.invalid/api/v1/',
      apiKey: 'test-key',
    );
    final second = await service.load(
      baseUrl: 'https://catalog-cache-test.invalid/api/v1',
      apiKey: 'test-key',
    );

    expect(requestCount, 1);
    expect(first.single.id, 'openai/gpt-4o-mini');
    expect(first.single.provider, 'openai');
    // No architecture block → text-only default.
    expect(first.single.inputModalities, ['text']);
    expect(identical(first, second), isTrue);
    service.close();
  });

  test('parses architecture.input_modalities and supportsInput', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'test/vision-model',
              'name': 'Vision',
              'architecture': {
                'input_modalities': ['text', 'image', 'file'],
                'output_modalities': ['text'],
              },
            },
            {
              'id': 'test/audio-model',
              'name': 'Audio',
              'architecture': {
                'input_modalities': ['text', 'audio'],
              },
            },
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    await service.load(
      baseUrl: 'https://catalog-modality-test.invalid/api/v1',
      apiKey: 'test-key',
    );

    expect(ModelCatalogService.supportsInput('test/vision-model', 'image'), isTrue);
    expect(ModelCatalogService.supportsInput('test/vision-model', 'audio'), isFalse,
        reason: 'catalog positively knows audio is unsupported');
    expect(ModelCatalogService.supportsInput('test/audio-model', 'audio'), isTrue);
    // Unknown model → null ("allow the attempt").
    expect(ModelCatalogService.supportsInput('unknown/model', 'image'), isNull);
    service.close();
  });

  test('loads standard OpenAI-compatible catalog (OpenCode Zen / Groq) without OpenRouter query params', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/models');
      expect(request.url.queryParameters.containsKey('output_modalities'), isFalse);
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'claude-3-5-sonnet', 'name': 'Claude 3.5 Sonnet'},
            {'id': 'gpt-4o'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    final models = await service.load(
      baseUrl: 'https://api.opencode.com/api/v1',
      apiKey: 'zen-token',
      defaultProvider: 'OpenCode Zen',
      isOpenRouter: false,
    );

    expect(models.length, 2);
    expect(models[0].id, 'claude-3-5-sonnet');
    expect(models[0].name, 'Claude 3.5 Sonnet');
    // Model ID has no slash → should use the provider name instead of "OpenRouter"
    expect(models[0].provider, 'OpenCode Zen');
    expect(models[1].id, 'gpt-4o');
    expect(models[1].name, 'gpt-4o');
    expect(models[1].provider, 'OpenCode Zen');

    // Without explicit architecture, supportsInput returns null ("allow attempt") for image
    expect(ModelCatalogService.supportsInput('claude-3-5-sonnet', 'image'), isNull);
    service.close();
  });

  test('testConnection returns success and count for valid endpoint', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'role': 'assistant', 'content': 'pong'}}
            ]
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'model-1'},
            {'id': 'model-2'},
            {'id': 'model-3'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    final result = await service.testConnection(
      baseUrl: 'https://api.groq.com/openai/v1',
      apiKey: 'gsk_test',
      defaultProvider: 'Groq',
      isOpenRouter: false,
    );

    expect(result.success, isTrue);
    expect(result.modelCount, 3);
    service.close();
  });

  test('testConnection catches 401 on /chat/completions even if /models returns 200', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        return http.Response(
          jsonEncode({'error': {'message': 'Invalid API key.'}}),
          401,
        );
      }
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'claude-sonnet-4'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);

    final result = await service.testConnection(
      baseUrl: 'https://opencode.ai/zen/v1',
      apiKey: 'invalid_key',
      defaultProvider: 'OpenCode Zen',
      isOpenRouter: false,
    );

    expect(result.success, isFalse);
    expect(result.message, contains('Authentication failed'));
    expect(result.message, contains('Invalid API key.'));
    service.close();
  });

  test('getCachedModels and hasCachedModels reflect session cache', () async {
    ModelCatalogService.clearCache();
    expect(ModelCatalogService.hasCachedModels('https://api.test.com/v1'), isFalse);
    expect(ModelCatalogService.getCachedModels('https://api.test.com/v1'), isNull);

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'test-model'},
          ],
        }),
        200,
      );
    });
    final service = ModelCatalogService(client: client);
    await service.load(baseUrl: 'https://api.test.com/v1', apiKey: 'k');

    expect(ModelCatalogService.hasCachedModels('https://api.test.com/v1'), isTrue);
    expect(ModelCatalogService.getCachedModels('https://api.test.com/v1')?.first.id, 'test-model');

    ModelCatalogService.clearCache(baseUrl: 'https://api.test.com/v1');
    expect(ModelCatalogService.hasCachedModels('https://api.test.com/v1'), isFalse);
    service.close();
  });

  test('testConnection returns failure on 401', () async {
    final client = MockClient((request) async {
      return http.Response('Unauthorized', 401);
    });
    final service = ModelCatalogService(client: client);

    final result = await service.testConnection(
      baseUrl: 'https://api.groq.com/openai/v1',
      apiKey: 'invalid_key',
      defaultProvider: 'Groq',
      isOpenRouter: false,
    );

    expect(result.success, isFalse);
    expect(result.message, contains('401'));
    service.close();
  });
}
