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

  @override
  Future<void> stopLoading() async {
    stopped = true;
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

  testWidgets('BrowserWidget renders expanded sheet when opened with expand: true', (tester) async {
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

    await service.open('https://flutter.dev', expand: true);
    await tester.pumpAndSettle();

    expect(find.text('https://flutter.dev'), findsAtLeast(1));
    expect(find.byKey(const ValueKey('browser_test_placeholder')), findsOneWidget);
    expect(find.byTooltip('Close browser'), findsOneWidget);
    expect(find.byTooltip('Collapse sheet'), findsOneWidget);
  });

  testWidgets('BrowserWidget renders collapsed mini bar when collapsed', (tester) async {
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

    await service.open('https://flutter.dev', expand: false);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Expand browser'), findsOneWidget);
    expect(find.byTooltip('Reload page'), findsOneWidget);

    // Tap expand button
    await tester.tap(find.byTooltip('Expand browser'));
    await tester.pumpAndSettle();

    expect(service.isExpanded, isTrue);
    expect(find.byTooltip('Collapse sheet'), findsOneWidget);

    // Tap collapse button
    await tester.tap(find.byTooltip('Collapse sheet'));
    await tester.pumpAndSettle();

    expect(service.isExpanded, isFalse);
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

    await service.open('https://flutter.dev', expand: false);
    await tester.pumpAndSettle();

    expect(service.isOpen, isTrue);

    await tester.tap(find.byKey(const ValueKey('browser_collapsed_close_button')));
    await tester.pumpAndSettle();

    expect(service.isOpen, isFalse);
  });
}
