import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/tavily_client.dart';
import 'package:errand/tools/web_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test(
    'websearch prompts agent to use webfetch fallback when API key is missing',
    () async {
      final result = await webSearchTavilyTool(keyResolver: () => null).handler(
        const ToolCall(
          id: 'search-no-key',
          name: 'websearch',
          arguments: {'query': 'flutter release notes'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Tavily API key is not configured'));
      expect(result.errorMessage, contains('webfetch still works'));
      expect(result.errorMessage, contains('https://lite.duckduckgo.com/lite/?q=flutter+release+notes'));
    },
  );

  test(
    'webfetch falls back to in-built fetcher when Tavily errors out (e.g. 429 quota)',
    () async {
      final tavily = TavilyClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          return http.Response('Rate limit / Quota exceeded', 429);
        }),
      );
      addTearDown(tavily.close);

      final fallbackHttp = MockClient((request) async {
        expect(request.url.toString(), 'https://example.com/quota-test');
        return http.Response(
          '''
<!DOCTYPE html>
<html>
<head><title>Fallback Article</title></head>
<body>
  <article>
    <h1>Fallback Article</h1>
    <p>Recovered using in-built fallback fetcher.</p>
  </article>
</body>
</html>
''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });

      final result = await webFetchTool(
        client: tavily,
        fallbackClient: fallbackHttp,
      ).handler(
        const ToolCall(
          id: 'fetch-quota-fallback',
          name: 'webfetch',
          arguments: {'url': 'https://example.com/quota-test'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Fallback Article'));
      expect(result.output, contains('Recovered using in-built fallback fetcher.'));
    },
  );

  test(
    'webfetch outputs error text when both Tavily and fallback fail',
    () async {
      final tavily = TavilyClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          return http.Response('Quota exceeded', 429);
        }),
      );
      addTearDown(tavily.close);

      final fallbackHttp = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final result = await webFetchTool(
        client: tavily,
        fallbackClient: fallbackHttp,
      ).handler(
        const ToolCall(
          id: 'fetch-both-fail',
          name: 'webfetch',
          arguments: {'url': 'https://example.com/missing-page'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('HTTP 404'));
    },
  );
}


