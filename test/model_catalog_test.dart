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
}
