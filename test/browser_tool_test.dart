import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/services/browser_service.dart';
import 'package:errand/tools/browser_tool.dart';

class FakeBrowserController implements BrowserController {
  String? url;
  String? title;
  bool canBack = false;
  bool canForward = false;
  bool reloaded = false;
  bool stopped = false;
  final List<String> executedScripts = [];
  dynamic jsResult;
  Uint8List? screenshotBytes;

  @override
  Future<void> loadUrl(String url) async {
    this.url = url;
    title ??= 'Test Title';
  }

  @override
  Future<void> reload() async {
    reloaded = true;
  }

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<bool> canGoBack() async => canBack;

  @override
  Future<bool> canGoForward() async => canForward;

  @override
  Future<dynamic> evaluateJavascript(String source) async {
    executedScripts.add(source);
    return jsResult;
  }

  @override
  Future<Uint8List?> takeScreenshot() async => screenshotBytes;

  @override
  Future<String?> getUrl() async => url;

  @override
  Future<String?> getTitle() async => title;

  bool timersPaused = false;

  @override
  Future<void> stopLoading() async {
    stopped = true;
  }

  @override
  Future<void> pauseTimers() async {
    timersPaused = true;
  }

  @override
  Future<void> resumeTimers() async {
    timersPaused = false;
  }
}

void main() {
  late FakeBrowserController fakeController;
  late BrowserService service;
  late Tool tool;

  setUp(() {
    fakeController = FakeBrowserController();
    service = BrowserService(controllerOverride: fakeController);
    tool = browserTool(browserService: service);
  });

  group('browserTool - action: open', () {
    test('opens page and returns formatted summary', () async {
      final call = ToolCall(
        id: 'c1',
        name: 'browser',
        arguments: {
          'action': 'open',
          'url': 'https://flutter.dev',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Opened browser at https://flutter.dev'));
      expect(result.output, contains('Status: loaded'));
      expect(service.isOpen, isTrue);
    });

    test('fails when url is missing or empty', () async {
      final call = ToolCall(
        id: 'c2',
        name: 'browser',
        arguments: {
          'action': 'open',
          'url': '',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('URL parameter is required'));
    });
  });

  group('browserTool - action: close and reload', () {
    test('closes browser', () async {
      await service.open('https://example.com');
      expect(service.isOpen, isTrue);

      final call = ToolCall(
        id: 'c3',
        name: 'browser',
        arguments: {'action': 'close'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, equals('Browser closed.'));
      expect(service.isOpen, isFalse);
    });

    test('reloads page', () async {
      await service.open('https://example.com');

      final call = ToolCall(
        id: 'c4',
        name: 'browser',
        arguments: {'action': 'reload'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Page reloaded.'));
      expect(fakeController.reloaded, isTrue);
    });
  });

  group('browserTool - action: snapshot and extract_text', () {
    test('extracts and returns Playwright-style accessibility tree with id and class', () async {
      await service.open('https://news.ycombinator.com');

      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://news.ycombinator.com',
          'title': 'Hacker News',
          'scroll': {'x': 0, 'y': 0, 'totalHeight': 2000},
        },
        'tree': '''- link "Comments" [ref=e1] [id="hn-link"] [class="storylink"] [cursor=pointer]:
  - /url: /item?id=1''',
      });

      final call = ToolCall(
        id: 'c5',
        name: 'browser',
        arguments: {'action': 'snapshot'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Page Title: Hacker News'));
      expect(result.output, contains('- link "Comments" [ref=e1] [id="hn-link"] [class="storylink"] [cursor=pointer]:'));
      expect(result.output, contains('  - /url: /item?id=1'));
    });

    test('snapshot with full_dump returns raw DOM HTML', () async {
      await service.open('https://example.com');
      fakeController.jsResult = '<html><body><h1>Pure HTML</h1></body></html>';

      final call = ToolCall(
        id: 'c5b',
        name: 'browser',
        arguments: {'action': 'snapshot', 'full_dump': true},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, equals('<html><body><h1>Pure HTML</h1></body></html>'));
    });

    test('extract_text converts page to clean Markdown', () async {
      await service.open('https://example.com');
      fakeController.jsResult = '<h1>Documentation</h1><p>Read the <em>guide</em>.</p>';

      final call = ToolCall(
        id: 'c5c',
        name: 'browser',
        arguments: {'action': 'extract_text'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('# Documentation'));
      expect(result.output, contains('Read the _guide_.'));
    });

    test('standalone extractTextTool works correctly', () async {
      final standaloneTool = extractTextTool(browserService: service);
      await service.open('https://example.com');
      fakeController.jsResult = '<h2>Section</h2><p>Content</p>';

      final call = ToolCall(
        id: 'c5d',
        name: 'extract_text',
        arguments: {},
      );

      final result = await standaloneTool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('## Section'));
      expect(result.output, contains('Content'));
    });
  });

  group('browserTool - action: execute_dom_js', () {
    test('evaluates javascript in DOM', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': true,
        'result': 'Sample Header',
      });

      final call = ToolCall(
        id: 'c6',
        name: 'browser',
        arguments: {
          'action': 'execute_dom_js',
          'script': 'document.querySelector("h1").innerText',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Sample Header'));
    });

    test('fails on missing script', () async {
      final call = ToolCall(
        id: 'c7',
        name: 'browser',
        arguments: {'action': 'execute_dom_js'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Missing "script" parameter'));
    });
  });

  group('browserTool - action: act', () {
    setUp(() async {
      await service.open('https://example.com');
    });

    test('performs click action', () async {
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'button',
        'text': 'Submit',
      });

      final call = ToolCall(
        id: 'c8',
        name: 'browser',
        arguments: {
          'action': 'act',
          'act_action': 'click',
          'ref': '1',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Clicked [1] <button> "Submit".'));
    });

    test('performs type action', () async {
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'input',
      });

      final call = ToolCall(
        id: 'c9',
        name: 'browser',
        arguments: {
          'action': 'act',
          'act_action': 'type',
          'ref': '2',
          'text': 'Search query',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Typed "Search query" into [2] <input>.'));
    });

    test('performs scroll action', () async {
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'scrollY': 300,
        'totalH': 1000,
      });

      final call = ToolCall(
        id: 'c10',
        name: 'browser',
        arguments: {
          'action': 'act',
          'act_action': 'scroll',
          'direction': 'down',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Scrolled down'));
    });
  });

  group('browserTool - screenshot and prefix calls', () {
    test('screenshot captures viewport', () async {
      await service.open('https://example.com');
      fakeController.screenshotBytes = Uint8List.fromList([1, 2, 3]);

      final call = ToolCall(
        id: 'c11',
        name: 'browser',
        arguments: {'action': 'screenshot'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Captured browser viewport screenshot (3 bytes)'));
      expect(result.contentParts, isNotNull);
      expect(result.contentParts!.first['type'], equals('image_url'));
      expect(
        result.contentParts!.first['image_url']['url'],
        equals('data:image/png;base64,${base64Encode([1, 2, 3])}'),
      );
    });

    test('handles browser.open prefix call', () async {
      final call = ToolCall(
        id: 'c12',
        name: 'browser.open',
        arguments: {'url': 'https://flutter.dev'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Opened browser at https://flutter.dev'));
    });

    test('handles browser.click prefix call', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'button',
      });

      final call = ToolCall(
        id: 'c13',
        name: 'browser.click',
        arguments: {'ref': '1'},
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Clicked [1] <button>.'));
    });
  });

  group('ToolRegistry routing for browser', () {
    test('routes browser and browser.snapshot through registry', () async {
      final registry = ToolRegistry([tool, extractTextTool(browserService: service)]);

      final openCall = ToolCall(
        id: 'c14',
        name: 'browser',
        arguments: {'action': 'open', 'url': 'https://example.com'},
      );
      final openRes = await registry.execute(openCall);
      expect(openRes.ok, isTrue);

      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://example.com',
          'title': 'Example',
          'scroll': {},
        },
        'nodes': [],
        'headings': [],
        'links': [],
        'forms': [],
      });

      final snapshotCall = ToolCall(
        id: 'c15',
        name: 'browser.snapshot',
        arguments: {},
      );
      final snapshotRes = await registry.execute(snapshotCall);
      expect(snapshotRes.ok, isTrue);
      expect(snapshotRes.output, contains('Page Title: Example'));
      expect(snapshotRes.output, contains('URL: https://example.com'));

      fakeController.jsResult = '<h1>Heading</h1><p>Body</p>';
      final extractCall = ToolCall(
        id: 'c16',
        name: 'extract_text',
        arguments: {},
      );
      final extractRes = await registry.execute(extractCall);
      expect(extractRes.ok, isTrue);
      expect(extractRes.output, contains('# Heading'));
    });
  });
}
