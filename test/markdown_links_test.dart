import 'package:errand/utils/markdown_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the shared Markdown link router used by chat bubbles and task
/// report previews. Only the http(s) and ignored-scheme branches are covered:
/// file-link branches need real filesystem roots unavailable in the test zone.
void main() {
  final List<MethodCall> intentCalls = [];
  late BuildContext tapContext;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    intentCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('intent'), (call) async {
      intentCalls.add(call);
      return 'ok';
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('intent'), null);
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              tapContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('https link opens externally via intent', (tester) async {
    await pumpContext(tester);

    await openMarkdownLink(tapContext, 'https://flutter.dev');

    final launches = intentCalls.where((c) => c.method == 'launch').toList();
    expect(launches, hasLength(1));
    final args = launches.single.arguments as Map;
    expect(args['action'], equals('open_url'));
    expect(args['data'], equals('https://flutter.dev'));
  });

  testWidgets('non-web, non-file scheme is ignored without intent', (tester) async {
    await pumpContext(tester);

    await openMarkdownLink(tapContext, 'mailto:hi@example.com');

    expect(intentCalls.where((c) => c.method == 'launch'), isEmpty);
  });
}
