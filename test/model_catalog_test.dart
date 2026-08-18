import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:handy_flutter/services/model_catalog.dart';

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
    expect(identical(first, second), isTrue);
    service.close();
  });
}
