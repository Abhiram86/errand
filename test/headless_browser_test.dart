import 'dart:convert';

import 'package:errand/agent/tool.dart';
import 'package:errand/services/browser_service.dart';
import 'package:errand/services/headless_browser_service.dart';
import 'package:errand/tools/browser_tool.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

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
  bool timersPaused = false;

  @override
  Future<void> loadUrl(String url) async {
    this.url = url;
    title ??= 'Headless Page Title';
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
  group('Slice 2: HeadlessBrowserService', () {
    late FakeBrowserController fakeController;
    late HeadlessBrowserService headlessService;

    setUp(() {
      fakeController = FakeBrowserController();
      headlessService = HeadlessBrowserService(controllerOverride: fakeController);
    });

    tearDown(() {
      headlessService.dispose();
    });

    test('initializes with fullScreen display mode (1.0 zoom scale)', () {
      expect(headlessService.displayMode, equals(BrowserDisplayMode.fullScreen));
      expect(headlessService.isOpen, isFalse);
    });

    test('open navigates controller offscreen', () async {
      final info = await headlessService.open('https://errand.example.com');
      expect(info.url, equals('https://errand.example.com'));
      expect(fakeController.url, equals('https://errand.example.com'));
      expect(headlessService.isOpen, isTrue);
    });

    test('supports full parity: reload, snapshot, text extraction, dom js, act', () async {
      await headlessService.open('https://errand.example.com');

      // Reload
      await headlessService.reload();
      expect(fakeController.reloaded, isTrue);

      // Execute DOM JS
      fakeController.jsResult = '42';
      final jsVal = await headlessService.executeDomJs('21 * 2');
      expect(jsVal, equals('Result: 42'));

      // Act
      fakeController.jsResult = jsonEncode({'ok': true, 'tag': 'button', 'text': 'Submit'});
      final actResult = await headlessService.act(action: 'click', ref: 'e1');
      expect(actResult, contains('Clicked [e1] <button> "Submit"'));
    });

    test('supports offscreen screenshot capture', () async {
      await headlessService.open('https://errand.example.com');
      final dummyPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      fakeController.screenshotBytes = dummyPng;

      final bytes = await headlessService.takeScreenshot();
      expect(bytes, isNotNull);
      expect(bytes, equals(dummyPng));
    });

    test('close and disposeHeadlessView cleanly resets state', () async {
      await headlessService.open('https://errand.example.com');
      expect(headlessService.isOpen, isTrue);

      await headlessService.close(clear: true);
      expect(headlessService.isOpen, isFalse);
    });
  });

  group('Slice 2: browserTool with isHeadless: true', () {
    late FakeBrowserController fakeController;
    late HeadlessBrowserService headlessService;
    late Tool tool;

    setUp(() {
      fakeController = FakeBrowserController();
      headlessService = HeadlessBrowserService(controllerOverride: fakeController);
      tool = browserTool(
        browserService: headlessService,
        isHeadless: true,
      );
    });

    tearDown(() {
      headlessService.dispose();
    });

    test('has headless-specific tool description', () {
      expect(tool.description, contains('Embedded headless web browser'));
      expect(tool.description, contains('offscreen without showing UI'));
    });

    test('executes action: open offscreen', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-open',
          name: 'browser',
          arguments: {
            'action': 'open',
            'url': 'https://errand.example.com',
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Opened browser at https://errand.example.com'));
      expect(fakeController.url, equals('https://errand.example.com'));
    });

    test('executes action: screenshot offscreen with base64 image part', () async {
      await tool.handler(
        const ToolCall(
          id: 'call-open',
          name: 'browser',
          arguments: {
            'action': 'open',
            'url': 'https://errand.example.com',
          },
        ),
      );

      final dummyPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      fakeController.screenshotBytes = dummyPng;

      final result = await tool.handler(
        const ToolCall(
          id: 'call-shot',
          name: 'browser',
          arguments: {
            'action': 'screenshot',
            'settle_ms': 0,
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Captured browser viewport screenshot'));
      expect(result.contentParts, isNotNull);
      expect(result.contentParts!.length, equals(1));
      expect(
        result.contentParts![0]['image_url']['url'],
        equals('data:image/png;base64,${base64Encode(dummyPng)}'),
      );
    });

    test('executes action: close offscreen', () async {
      await tool.handler(
        const ToolCall(
          id: 'call-open',
          name: 'browser',
          arguments: {
            'action': 'open',
            'url': 'https://errand.example.com',
          },
        ),
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'call-close',
          name: 'browser',
          arguments: {
            'action': 'close',
            'clear': true,
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, equals('Browser closed.'));
      expect(headlessService.isOpen, isFalse);
    });

    test('dispose and disposeHeadlessView run cleanly without throwing post-disposal errors (P12.4)', () async {
      final freshService = HeadlessBrowserService(controllerOverride: fakeController);
      expect(freshService.isDisposed, isFalse);

      freshService.dispose();
      expect(freshService.isDisposed, isTrue);

      // Subsequent async or manual calls should be safe
      await expectLater(freshService.disposeHeadlessView(), completes);
      expect(() => freshService.setController(null), returnsNormally);
    });
  });
}
