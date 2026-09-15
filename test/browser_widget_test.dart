import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/browser_service.dart';
import 'package:errand/widgets/browser_widget.dart';

class FakeBrowserController implements BrowserController {
  String? url;
  String? title;
  bool canBack = false;
  bool canForward = false;
  bool reloaded = false;
  bool stopped = false;

  @override
  Future<void> loadUrl(String url) async {
    this.url = url;
    title ??= 'Test Page Title';
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
  Future<dynamic> evaluateJavascript(String source) async => null;

  @override
  Future<Uint8List?> takeScreenshot() async => null;

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

  testWidgets('BrowserWidget renders nothing when closed and never opened', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BrowserWidget(service: service),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(BrowserWidget), findsOneWidget);
    expect(find.text('Browser'), findsNothing);
    expect(find.byKey(const ValueKey('browser_test_placeholder')), findsNothing);
  });

  testWidgets('BrowserWidget renders preview card when open in preview mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BrowserWidget(service: service),
            ],
          ),
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setPreview();
    await tester.pumpAndSettle();

    expect(find.text('https://flutter.dev'), findsAtLeast(1));
    expect(find.byKey(const ValueKey('browser_test_placeholder')), findsOneWidget);
    expect(find.byTooltip('Close browser'), findsOneWidget);
    expect(find.byTooltip('Open full screen'), findsOneWidget);
    expect(find.byTooltip('Minimize to dock'), findsOneWidget);
  });

  testWidgets('BrowserWidget renders closed dock bar when in closed mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BrowserWidget(service: service),
            ],
          ),
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setClosed();
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open preview'), findsOneWidget);
    expect(find.byTooltip('Open full screen'), findsOneWidget);
    expect(find.byTooltip('Reload page'), findsOneWidget);
    expect(find.byTooltip('Close browser'), findsOneWidget);

    // Tap preview button to enter preview
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();

    expect(service.displayMode, equals(BrowserDisplayMode.preview));
    expect(find.byTooltip('Minimize to dock'), findsOneWidget);

    // Tap minimize button to return to closed bar
    await tester.tap(find.byTooltip('Minimize to dock'));
    await tester.pumpAndSettle();

    expect(service.displayMode, equals(BrowserDisplayMode.closed));
  });

  testWidgets('BrowserWidget renders fullScreen overlay and can restore to preview', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BrowserWidget(service: service),
            ],
          ),
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setFullScreen();
    await tester.pumpAndSettle();

    expect(service.displayMode, equals(BrowserDisplayMode.fullScreen));
    expect(find.byTooltip('Exit full screen'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser_test_placeholder')), findsOneWidget);

    // Tap restore button
    await tester.tap(find.byTooltip('Exit full screen'));
    await tester.pumpAndSettle();

    expect(service.displayMode, equals(BrowserDisplayMode.preview));
    expect(find.byTooltip('Open full screen'), findsOneWidget);
  });

  testWidgets('Close button closes browser', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BrowserWidget(service: service),
            ],
          ),
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setClosed();
    await tester.pumpAndSettle();

    expect(service.isOpen, isTrue);

    await tester.tap(find.byKey(const ValueKey('browser_collapsed_close_button')));
    await tester.pumpAndSettle();

    expect(service.isOpen, isFalse);
  });

  testWidgets('BrowserDockSpacer reserves space in closed and preview modes but collapses in fullScreen and closed state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BrowserDockSpacer(service: service),
            ],
          ),
        ),
      ),
    );

    // Initially closed: spacer is 0 height
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(0));

    // Open in closed mode
    await service.open('https://flutter.dev');
    service.setClosed();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(54));

    // Preview mode
    service.setPreview();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, greaterThan(200));

    // Fullscreen mode: collapses to 0 because full overlay covers screen
    service.setFullScreen();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(0));

    // Close browser: collapses to 0
    await service.close();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(0));
  });

  testWidgets('BrowserDockSpacer and BrowserWidget compact to closed dock bar only when composer is focused', (tester) async {
    final composerKey = GlobalKey();
    final focusNotifier = ValueNotifier<bool>(false);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: focusNotifier,
          builder: (context, isFocused, _) {
            return Scaffold(
              body: Stack(
                children: [
                  Column(
                    children: [
                      BrowserDockSpacer(
                        service: service,
                        isComposerFocused: isFocused,
                      ),
                      SizedBox(key: composerKey, height: 68),
                    ],
                  ),
                  BrowserWidget(
                    service: service,
                    composerKey: composerKey,
                    isComposerFocused: isFocused,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setPreview();
    await tester.pumpAndSettle();

    // Normal preview height when composer is not focused
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, greaterThan(200));

    // When composer gets focused, browser compacts to closed dock bar
    focusNotifier.value = true;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(54));

    // When composer loses focus (or typing in webview input), restores preview
    focusNotifier.value = false;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, greaterThan(200));
  });
}
