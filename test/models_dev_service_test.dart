import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:errand/services/model_catalog.dart';
import 'package:errand/services/models_dev_service.dart';

void main() {
  setUp(() {
    ModelsDevService.clearCache();
    ModelCatalogService.clearCache();
  });

  group('ModelsDevService seeded limit lookups', () {
    test('resolves prominent model limits without network request', () {
      expect(ModelsDevService.lookupContextTokens('anthropic/claude-3.7-sonnet'), 200000);
      expect(ModelsDevService.lookupContextTokens('openai/gpt-4o'), 128000);
      expect(ModelsDevService.lookupContextTokens('google/gemini-2.0-flash'), 1048576);
      expect(ModelsDevService.lookupContextTokens('meta-llama/llama-3.3-70b-instruct'), 128000);
      expect(ModelsDevService.lookupContextTokens('llama-3.3-70b-versatile'), 128000);
      expect(ModelsDevService.lookupContextTokens('llama-3.1-8b-instant'), 128000);
      expect(ModelsDevService.lookupContextTokens('mixtral-8x7b-32768'), 32768);
    });

    test('extracts context limit from model name if explicit (e.g. 32k, 1m)', () {
      expect(ModelsDevService.lookupContextTokens('my-custom-model-64k'), 64 * 1024);
      expect(ModelsDevService.lookupContextTokens('big-brain-1m'), 1024 * 1024);
    });

    test('returns null for completely unrecognized random model names', () {
      expect(ModelsDevService.lookupContextTokens('unknown-xyz-model-v1'), isNull);
    });
  });

  group('ModelsDevService dynamic fetching', () {
    test('fetches and populates cache from models.dev JSON', () async {
      final mockResponse = jsonEncode({
        'acme/roadrunner-9b': {
          'id': 'acme/roadrunner-9b',
          'name': 'Roadrunner 9B',
          'limit': {'context': 65536, 'output': 8192},
          'modalities': {
            'input': ['text', 'image'],
            'output': ['text'],
          },
        },
        'acme/coyote-70b': {
          'id': 'acme/coyote-70b',
          'name': 'Coyote 70B',
          'limit': {'context': 131072, 'output': 16384},
          'modalities': {
            'input': ['text'],
            'output': ['text'],
          },
        }
      });

      final mockClient = MockClient((request) async {
        if (request.url.toString() == ModelsDevService.modelsDevUrl) {
          return http.Response(mockResponse, 200);
        }
        return http.Response('Not found', 404);
      });

      final service = ModelsDevService(client: mockClient);
      await service.load();

      expect(ModelsDevService.lookupContextTokens('acme/roadrunner-9b'), 65536);
      expect(ModelsDevService.lookupContextTokens('roadrunner-9b'), 65536);
      expect(ModelsDevService.lookupContextTokens('coyote-70b'), 131072);

      // Modalities lookups
      expect(ModelsDevService.lookupInputModalities('acme/roadrunner-9b'), ['text', 'image']);
      expect(ModelsDevService.lookupInputModalities('roadrunner-9b'), ['text', 'image']);
      expect(ModelsDevService.lookupInputModalities('coyote-70b'), ['text']);

      expect(ModelsDevService.supportsInputModality('roadrunner-9b', 'image'), isTrue);
      expect(ModelsDevService.supportsInputModality('coyote-70b', 'image'), isFalse);
      expect(ModelsDevService.supportsInputModality('coyote-70b', 'text'), isTrue);
      expect(ModelsDevService.supportsInputModality('unknown-model', 'image'), isNull);

      // ModelCatalogService integration fallback check
      expect(ModelCatalogService.supportsInput('roadrunner-9b', 'image'), isTrue);
      expect(ModelCatalogService.supportsInput('coyote-70b', 'image'), isFalse);
    });
  });

  group('ModelCatalogService.getContextLength integration', () {
    test('uses cached model contextLength when available', () {
      final catalog = ModelCatalogService();
      // Directly check fallback lookup
      expect(
        ModelCatalogService.getContextLength('anthropic/claude-3.7-sonnet'),
        200000,
      );
      expect(
        ModelCatalogService.getContextLength('google/gemini-2.0-flash-001'),
        1048576,
      );
      expect(
        ModelCatalogService.getContextLength('gpt-4o'),
        128000,
      );
      catalog.close();
    });

    test('falls back to 128k default if model is entirely unknown', () {
      expect(
        ModelCatalogService.getContextLength('completely-mysterious-model'),
        128000,
      );
    });
  });
}
