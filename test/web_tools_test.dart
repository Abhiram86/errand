import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/tavily_client.dart';
import 'package:errand/tools/web_tools.dart';

void main() {
  test('websearch formats Tavily results for the agent', () async {
    final client = TavilyClient(
      apiKey: 'test-key',
      client: MockClient((request) async {
        expect(request.url.path, '/search');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], 'Flutter documentation');
        expect(body['search_depth'], 'basic');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'title': 'Flutter docs',
                'url': 'https://docs.flutter.dev',
                'content': 'Official Flutter documentation.',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final result = await webSearchTavilyTool(client: client).handler(
      const ToolCall(
        id: 'search-1',
        name: 'websearch',
        arguments: {'query': 'Flutter documentation'},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('Flutter docs'));
    expect(result.output, contains('https://docs.flutter.dev'));
  });

  test(
    'webfetch requests Markdown extraction and returns page content',
    () async {
      final client = TavilyClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          expect(request.url.path, '/extract');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['urls'], ['https://example.com/article']);
          expect(body['format'], 'markdown');
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'url': 'https://example.com/article',
                  'raw_content': '# Article\n\nReadable Markdown content.',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final result = await webFetchTool(client: client).handler(
        const ToolCall(
          id: 'fetch-1',
          name: 'webfetch',
          arguments: {'url': 'https://example.com/article'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('# Article'));
      expect(result.output, contains('Readable Markdown content.'));
    },
  );
}
