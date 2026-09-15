import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/browser_service.dart';

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
    title ??= 'Sample Webpage';
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

  setUp(() {
    fakeController = FakeBrowserController();
    service = BrowserService(controllerOverride: fakeController);
  });

  group('BrowserService lifecycle & navigation', () {
    test('initial state is closed and unexpanded', () {
      expect(service.isOpen, isFalse);
      expect(service.isExpanded, isFalse);
      expect(service.currentUrl, isNull);
      expect(service.currentTitle, isNull);
    });

    test('open sets state and navigates controller', () async {
      final info = await service.open('https://example.com');
      expect(service.isOpen, isTrue);
      expect(service.isExpanded, isTrue);
      expect(service.currentUrl, equals('https://example.com'));
      expect(info.url, equals('https://example.com'));
      expect(fakeController.url, equals('https://example.com'));
    });

    test('open prefixes https if protocol missing', () async {
      await service.open('flutter.dev');
      expect(fakeController.url, equals('https://flutter.dev'));
    });

    test('open ignores spurious about:blank callbacks before target URL completes', () async {
      final realService = BrowserService();
      final openFuture = realService.open('https://flutter.dev', timeout: const Duration(seconds: 2));

      // Simulate native platform view mounting and firing about:blank
      realService.setController(FakeBrowserController());
      realService.onLoadStart('about:blank');
      realService.onLoadStop('about:blank');
      expect(realService.currentUrl, equals('https://flutter.dev'));

      // Simulate target page loading
      realService.onLoadStart('https://flutter.dev');
      realService.onLoadStop('https://flutter.dev');

      final info = await openFuture;
      expect(info.url, equals('https://flutter.dev'));
      expect(realService.currentUrl, equals('https://flutter.dev'));
    });

    test('ignores subresource errors when isForMainFrame is false', () async {
      service.onLoadStart('https://huggingface.co');
      service.onLoadError('https://huggingface.co/favicon.ico', 'HTTP 404', isForMainFrame: false);
      expect(service.lastError, isNull);

      service.onLoadStop('https://huggingface.co');
      expect(service.lastError, isNull);
    });

    test('open reports loaded status even if subresource 404 occurred during load', () async {
      final realService = BrowserService();
      final openFuture = realService.open('https://huggingface.co', timeout: const Duration(seconds: 2));

      final controller = FakeBrowserController();
      controller.title = 'Hugging Face – The AI community building the future.';
      realService.setController(controller);

      realService.onLoadStart('https://huggingface.co');
      // Subresource 404 (e.g. missing asset)
      realService.onLoadError('https://huggingface.co/front/assets/missing.png', 'HTTP 404', isForMainFrame: false);
      realService.onLoadStop('https://huggingface.co');

      final info = await openFuture;
      expect(info.url, equals('https://huggingface.co'));
      expect(info.title, contains('Hugging Face'));
      expect(info.status, equals('loaded'));
    });

    test('failed navigation reports error and does not retain prior title', () async {
      final realService = BrowserService();
      final controller = FakeBrowserController();
      controller.title = 'Initial Success Page';
      realService.setController(controller);

      // First navigation succeeds
      final open1 = realService.open('https://example.com');
      realService.onLoadStart('https://example.com');
      realService.onLoadStop('https://example.com');
      final info1 = await open1;
      expect(info1.status, equals('loaded'));
      expect(info1.title, equals('Initial Success Page'));

      // Second navigation fails on main frame
      final open2 = realService.open('https://example.com/not-found');
      realService.onLoadStart('https://example.com/not-found');
      realService.onLoadError('https://example.com/not-found', 'HTTP 404', isForMainFrame: true);
      final info2 = await open2;
      expect(info2.status, equals('error: HTTP 404'));
      expect(info2.title, isEmpty);
    });

    test('timed out navigation reports timeout error', () async {
      final realService = BrowserService();
      final controller = FakeBrowserController();
      realService.setController(controller);

      final openFuture = realService.open(
        'https://slow-website.com',
        timeout: const Duration(milliseconds: 100),
      );
      realService.onLoadStart('https://slow-website.com');
      // No onLoadStop fired before timeout
      final info = await openFuture;
      expect(info.status, contains('error: Navigation timed out'));
    });

    test('close pauses timers and stops loading, open resumes timers', () async {
      await service.open('https://example.com');
      expect(fakeController.timersPaused, isFalse);

      await service.close();
      expect(fakeController.stopped, isTrue);
      expect(fakeController.timersPaused, isTrue);

      await service.open('https://example.com');
      expect(fakeController.timersPaused, isFalse);
    });

    test('close resets open and expanded state', () async {
      await service.open('https://example.com');
      expect(service.isOpen, isTrue);

      await service.close();
      expect(service.isOpen, isFalse);
      expect(service.isExpanded, isFalse);
    });

    test('close with clear clears page to about:blank', () async {
      await service.open('https://example.com');
      await service.close(clear: true);
      expect(fakeController.url, equals('about:blank'));
      expect(service.currentUrl, isNull);
    });

    test('toggleExpand and setExpanded work correctly', () {
      expect(service.isExpanded, isFalse);
      service.expand();
      expect(service.isExpanded, isTrue);
      service.collapse();
      expect(service.isExpanded, isFalse);
      service.toggleExpand();
      expect(service.isExpanded, isTrue);
    });

    test('displayMode controls switch between closed, preview, and fullScreen', () async {
      await service.open('https://example.com');
      expect(service.displayMode, equals(BrowserDisplayMode.preview));
      expect(service.isExpanded, isTrue);

      service.setClosed();
      expect(service.displayMode, equals(BrowserDisplayMode.closed));
      expect(service.isExpanded, isFalse);

      service.setFullScreen();
      expect(service.displayMode, equals(BrowserDisplayMode.fullScreen));
      expect(service.isExpanded, isTrue);

      service.setPreview();
      expect(service.displayMode, equals(BrowserDisplayMode.preview));
      expect(service.isExpanded, isTrue);
    });

    test('reload triggers controller reload', () async {
      await service.open('https://example.com');
      await service.reload();
      expect(fakeController.reloaded, isTrue);
    });

    test('stopLoading updates state and controller', () async {
      await service.open('https://example.com');
      await service.stopLoading();
      expect(fakeController.stopped, isTrue);
      expect(service.isLoading, isFalse);
    });
  });

  group('BrowserService DOM extraction & interaction', () {
    test('snapshot returns Playwright-style accessibility tree with interactive elements, id, and class', () async {
      await service.open('https://news.ycombinator.com');

      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://news.ycombinator.com',
          'title': 'Hacker News',
          'scroll': {'x': 0, 'y': 120, 'totalHeight': 3400},
        },
        'tree': '''- link "Hacker News" [ref=e1] [id="hn-logo"] [class="brand-logo"] [cursor=pointer]:
  - /url: https://news.ycombinator.com
- button "Submit" [ref=e2] [id="btn-submit"] [class="btn btn-primary"] [cursor=pointer]
- textbox "Search" [ref=e3] [id="search-query"] [class="form-input"] [value="flutter"]
- heading "Top Stories" [ref=e4] [level=1]''',
      });

      final output = await service.snapshot();
      expect(output, contains('Page Title: Hacker News'));
      expect(output, contains('URL: https://news.ycombinator.com'));
      expect(output, contains('Scroll: (0, 120) / 3400px'));
      expect(output, contains('- link "Hacker News" [ref=e1] [id="hn-logo"] [class="brand-logo"] [cursor=pointer]:'));
      expect(output, contains('  - /url: https://news.ycombinator.com'));
      expect(output, contains('- button "Submit" [ref=e2] [id="btn-submit"] [class="btn btn-primary"] [cursor=pointer]'));
      expect(output, contains('- textbox "Search" [ref=e3] [id="search-query"] [class="form-input"] [value="flutter"]'));
      expect(output, contains('- heading "Top Stories" [ref=e4] [level=1]'));
    });

    test('snapshot fallback formats nodes list when tree string is not provided', () async {
      await service.open('https://news.ycombinator.com');

      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://news.ycombinator.com',
          'title': 'Hacker News',
          'scroll': {'x': 0, 'y': 0, 'totalHeight': 1000},
        },
        'nodes': [
          {
            'ref': 'e1',
            'tag': 'a',
            'role': 'link',
            'id': 'hn-logo',
            'class': 'brand-logo',
            'name': 'Hacker News',
            'href': 'https://news.ycombinator.com',
          }
        ]
      });

      final output = await service.snapshot();
      expect(output, contains('Page Title: Hacker News'));
      expect(output, contains('- link "Hacker News" [ref=e1] [id="hn-logo"] [class="brand-logo"] [cursor=pointer]:'));
      expect(output, contains('  - /url: https://news.ycombinator.com'));
    });

    test('snapshot with fullDump returns pure DOM dump', () async {
      await service.open('https://example.com');
      fakeController.jsResult = '<html><head><title>Pure DOM</title></head><body><h1>Hello World</h1></body></html>';

      final output = await service.snapshot(fullDump: true);
      expect(output, equals('<html><head><title>Pure DOM</title></head><body><h1>Hello World</h1></body></html>'));
      expect(fakeController.executedScripts.last, contains('document.documentElement.outerHTML'));
    });

    test('extractText converts HTML to clean Markdown via html2md', () async {
      await service.open('https://example.com');
      fakeController.jsResult = '<h1>Article Title</h1><p>This is a <strong>great</strong> article with a <a href="https://example.com">link</a>.</p>';

      final markdown = await service.extractText();
      expect(markdown, contains('# Article Title'));
      expect(markdown, contains('This is a **great** article with a [link](https://example.com).'));
    });

    test('executeDomJs wraps and evaluates expression', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': true,
        'result': 42,
        'type': 'number',
      });

      final res = await service.executeDomJs('21 * 2');
      expect(res, equals('Result: 42'));
      expect(fakeController.executedScripts.last, contains('21 * 2'));
    });

    test('executeDomJs reports errors gracefully', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': false,
        'error': 'ReferenceError: foo is not defined',
      });

      final res = await service.executeDomJs('foo.bar()');
      expect(res, contains('JavaScript error: ReferenceError: foo is not defined'));
    });

    test('act click executes click by ref', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'button',
        'text': 'Login',
      });

      final res = await service.act(action: 'click', ref: '2');
      expect(res, equals('Clicked [2] <button> "Login".'));
    });

    test('act type executes typing by ref', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'input',
      });

      final res = await service.act(action: 'type', ref: '3', text: 'Errand AI');
      expect(res, equals('Typed "Errand AI" into [3] <input>.'));
    });

    test('act scroll executes scrolling down', () async {
      await service.open('https://example.com');

      fakeController.jsResult = jsonEncode({
        'ok': true,
        'scrollY': 400,
        'totalH': 1200,
      });

      final res = await service.act(action: 'scroll', direction: 'down');
      expect(res, contains('Scrolled down (current scroll: 400px / 1200px).'));
    });

    test('takeScreenshot returns viewport bytes', () async {
      await service.open('https://example.com');
      fakeController.screenshotBytes = Uint8List.fromList([1, 2, 3, 4]);

      final bytes = await service.takeScreenshot();
      expect(bytes, isNotNull);
      expect(bytes!.length, equals(4));
    });

    test('snapshot formats traversal budget truncation', () async {
      await service.open('https://news.ycombinator.com');
      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://news.ycombinator.com',
          'title': 'Hacker News',
          'scroll': {'x': 0, 'y': 0, 'totalHeight': 1000},
        },
        'tree': '- link "Hacker News" [ref=e1]',
        'stats': {
          'nodeCount': 50,
          'visitedCount': 1500,
          'truncated': true,
          'reason': 'traversal_budget',
        },
      });

      final output = await service.snapshot();
      expect(output, contains('[Snapshot capped by traversal/time budget (1500 elements visited)]'));
    });

    test('snapshot fullDump formats paginated chunk with metadata', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'chunk': '<html><body>Hello Paginated Chunk</body></html>',
        'total': 5000,
        'offset': 100,
        'hasMore': true,
      });

      final output = await service.snapshot(fullDump: true, dumpOffset: 100, dumpLimit: 50);
      expect(output, contains('<!-- DOM Dump chunk [100..147 of 5000 chars] -->'));
      expect(output, contains('<html><body>Hello Paginated Chunk</body></html>'));
      expect(output, contains('<!-- [More DOM content available: call snapshot(full_dump: true, dump_offset: 147)] -->'));
    });

    test('extractText reports truncation when HTML exceeds maxChars', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'html': '<h1>Truncated Article</h1><p>Partial text...</p>',
        'truncated': true,
        'total': 300000,
      });

      final text = await service.extractText(maxChars: 150000);
      expect(text, contains('# Truncated Article'));
      expect(text, contains('[Content truncated at 150000 characters. Pass selector for specific section.]'));
    });

    test('executeDomJs reports capped result when serialized output exceeds maxChars', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'result': 'very long string...',
        'type': 'string',
        'truncated': true,
      });

      final res = await service.executeDomJs('largeData()', maxChars: 50000);
      expect(res, contains('Result: "very long string..."'));
      expect(res, contains('[Result capped at 50000 characters]'));
    });

    test('act click on checkbox returns checked status confirmation', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'input',
        'checked': true,
      });

      final res = await service.act(action: 'click', ref: 'e4');
      expect(res, equals('Clicked [e4] <input>. (checked: true)'));
    });

    test('act type returns confirmed current value', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'input',
        'value': 'john@example.com',
      });

      final res = await service.act(action: 'type', ref: 'e2', text: 'john@example.com');
      expect(res, equals('Typed "john@example.com" into [e2] <input>. (current value: "john@example.com")'));
    });

    test('act select chooses option in select dropdown', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'select',
        'text': 'California',
        'value': 'CA',
      });

      final res = await service.act(action: 'select', ref: 'e5', text: 'California');
      expect(res, equals('Selected "California" (value: "CA") in [e5] <select>.'));
    });

    test('act get returns targeted element properties', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'ok': true,
        'tag': 'input',
        'id': 'username',
        'value': 'admin',
        'checked': null,
        'disabled': false,
        'text': 'Username Input',
      });

      final res = await service.act(action: 'get', ref: 'e1');
      expect(res, contains('Element [e1] <input id="username">: value: "admin", text: "Username Input".'));
    });

    test('snapshot with ref or selector includes scope in output', () async {
      await service.open('https://example.com');
      fakeController.jsResult = jsonEncode({
        'meta': {
          'url': 'https://example.com',
          'title': 'Form Page',
          'scoped': '[ref=e3]',
          'scroll': {'x': 0, 'y': 0, 'totalHeight': 800},
        },
        'tree': '- form [ref=e3]:\n  - textbox "Name" [ref=e4]',
        'stats': {'nodeCount': 2, 'visitedCount': 10, 'truncated': false},
      });

      final res = await service.snapshot(ref: 'e3');
      expect(res, contains('Scope: [ref=e3]'));
      expect(res, contains('- form [ref=e3]:'));
    });

    test('syncs zoom on preview and fullScreen display modes', () async {
      await service.open('https://example.com');
      expect(fakeController.executedScripts.any((s) => s.contains("style.zoom = '0.80'")), isTrue);

      service.setFullScreen();
      await Future.delayed(Duration.zero);
      expect(fakeController.executedScripts.any((s) => s.contains("style.zoom = '1.0'")), isTrue);

      service.setPreview();
      await Future.delayed(Duration.zero);
      expect(fakeController.executedScripts.last, contains("style.zoom = '0.80'"));
    });

    test('throws StateError when operating on closed browser', () async {
      expect(() => service.snapshot(), throwsStateError);
      expect(() => service.executeDomJs('1+1'), throwsStateError);
      expect(() => service.act(action: 'click', ref: '1'), throwsStateError);
      expect(() => service.takeScreenshot(), throwsStateError);
    });
  });
}
