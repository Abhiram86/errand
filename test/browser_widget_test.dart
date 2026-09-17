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

  testWidgets('tapping preview when focused on composer unfocuses composer', (tester) async {
    final composerKey = GlobalKey();
    final focusNotifier = ValueNotifier<bool>(false);
    bool unfocusCallbackCalled = false;

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
                    onUnfocusComposer: () {
                      unfocusCallbackCalled = true;
                      focusNotifier.value = false;
                    },
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

    // Focus composer -> browser compacts
    focusNotifier.value = true;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, equals(54));

    // Tap on the preview button in the compact dock bar
    await tester.tap(find.byKey(const ValueKey('browser_preview_button')));
    await tester.pumpAndSettle();

    // Verify callback was called and preview expanded back
    expect(unfocusCallbackCalled, isTrue);
    expect(focusNotifier.value, isFalse);
    expect(tester.getSize(find.byType(BrowserDockSpacer)).height, greaterThan(200));
  });

  testWidgets('BrowserWidget toolbar displays Open in external browser button', (tester) async {
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

    expect(find.byKey(const ValueKey('browser_open_external_button')), findsOneWidget);
    expect(find.byTooltip('Open in external browser'), findsOneWidget);

    service.setFullScreen();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('browser_open_external_button')), findsOneWidget);
  });

  testWidgets('OAuthPopupDialog renders and dismisses on close button tap', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OAuthPopupDialog(
            windowId: 42,
          ),
        ),
      ),
    );

    expect(find.byType(OAuthPopupDialog), findsOneWidget);
    expect(find.text('Authentication'), findsAtLeast(1));
    expect(find.byIcon(Icons.security_rounded), findsAtLeast(1));
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byKey(const ValueKey('oauth_popup_test_placeholder')), findsOneWidget);

    // Test dismiss inside a dialog
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const OAuthPopupDialog(windowId: 101),
              ),
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    expect(find.byType(OAuthPopupDialog), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(OAuthPopupDialog), findsNothing);
  });

  testWidgets('BrowserWidget toolbar renders on narrow 320px screen without overflow in preview and fullScreen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserWidget(service: service),
        ),
      ),
    );

    await service.open('https://flutter.dev');
    service.setPreview();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('browser_reload_button')), findsOneWidget);

    service.setFullScreen();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('browser_reload_button')), findsOneWidget);
  });
}

