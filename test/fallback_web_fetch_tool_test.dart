import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/tools/fallback_web_fetch_tool.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fallbackWebFetchTool parses HTML article into readable Markdown', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.toString(), 'https://example.com/flutter-article');
      return http.Response(
        '''
<!DOCTYPE html>
<html>
<head><title>Flutter Architecture Overview</title></head>
<body>
  <nav><a href="/">Home</a><a href="/docs">Docs</a></nav>
  <article>
    <h1>Flutter Architecture Overview</h1>
    <p>Flutter is an open source framework by Google for building multi-platform applications.</p>
    <h2>Core Concepts</h2>
    <p>Widgets are the basic building blocks of a Flutter user interface. Visit <a href="https://flutter.dev">Flutter</a> to learn more.</p>
  </article>
  <footer>Copyright 2026</footer>
</body>
</html>
''',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });

    final tool = fallbackWebFetchTool(client: mockClient);
    final result = await tool.handler(
      const ToolCall(
        id: 'fetch-test-1',
        name: 'webfetch',
        arguments: {'url': 'https://example.com/flutter-article'},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('Source: https://example.com/flutter-article'));
    expect(result.output, contains('Flutter Architecture Overview'));
    expect(result.output, contains('open source framework'));
    expect(result.output, contains('[Flutter](https://flutter.dev/)'));
    // Nav and footer should be stripped
    expect(result.output.contains('Copyright 2026'), isFalse);
  });

  test('fallbackWebFetchTool handles non-HTML plain text response', () async {
    final mockClient = MockClient((request) async {
      return http.Response(
        'Plain text document content.',
        200,
        headers: {'content-type': 'text/plain'},
      );
    });

    final tool = fallbackWebFetchTool(client: mockClient);
    final result = await tool.handler(
      const ToolCall(
        id: 'fetch-test-2',
        name: 'webfetch',
        arguments: {'url': 'https://example.com/notes.txt'},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('Plain text document content.'));
  });

  test('fallbackWebFetchTool fails on HTTP errors', () async {
    final mockClient = MockClient((request) async {
      return http.Response('Not Found', 404);
    });

    final tool = fallbackWebFetchTool(client: mockClient);
    final result = await tool.handler(
      const ToolCall(
        id: 'fetch-test-3',
        name: 'webfetch',
        arguments: {'url': 'https://example.com/missing'},
      ),
    );

    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('HTTP 404'));
  });

  test('fallbackWebFetchTool rejects invalid URLs', () async {
    final tool = fallbackWebFetchTool();
    final result = await tool.handler(
      const ToolCall(
        id: 'fetch-test-4',
        name: 'webfetch',
        arguments: {'url': 'ftp://invalid-scheme.com'},
      ),
    );

    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('URL must be a valid HTTP or HTTPS URL'));
  });

  test('ToolRegistry.defaults registers webfetch even without Tavily key', () {
    final registry = ToolRegistry.defaults(currentDir: Directory('/'));
    final webFetch = registry.all.firstWhere((t) => t.name == 'webfetch');
    expect(webFetch, isNotNull);
    expect(webFetch.name, 'webfetch');
  });

  test('fallbackWebFetchTool caps raw response bytes and marks truncation', () async {
    final mockClient = MockClient((request) async {
      return http.Response(
        'A' * 1000,
        200,
        headers: {'content-type': 'text/plain'},
      );
    });

    final tool = fallbackWebFetchTool(
      client: mockClient,
      maxRawBytes: 200,
    );
    final result = await tool.handler(
      const ToolCall(
        id: 'cap-test',
        name: 'webfetch',
        arguments: {'url': 'https://example.com/large.txt'},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('[Note: raw webpage exceeded'));
  });

  test('fallbackWebFetchTool aborts on stream inactivity timeout', () async {
    final controller = StreamController<List<int>>();
    final mockClient = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        controller.stream,
        200,
        headers: {'content-type': 'text/plain'},
      );
    });

    final tool = fallbackWebFetchTool(
      client: mockClient,
      inactivityTimeout: const Duration(milliseconds: 50),
    );

    // Feed a few bytes then stall
    controller.add([65, 65]);

    final result = await tool.handler(
      const ToolCall(
        id: 'stall-test',
        name: 'webfetch',
        arguments: {'url': 'https://example.com/stall'},
      ),
    );

    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('inactivity timeout'));

    await controller.close();
  });
}
