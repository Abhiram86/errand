import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WidgetService widgetService;
  const channel = MethodChannel('widget');

  setUp(() {
    widgetService = WidgetService.instance;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('consumeInitialVoicePrompt requests status from native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'consumeInitialVoicePrompt') {
        return true;
      }
      return null;
    });

    final result = await widgetService.consumeInitialVoicePrompt();
    expect(result, isTrue);
  });

  test('onVoicePrompt stream emits when native calls onVoicePrompt', () async {
    widgetService.initialize();

    bool emitted = false;
    final sub = widgetService.onVoicePrompt.listen((_) {
      emitted = true;
    });

    // Simulate incoming method call from native Android
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final ByteData data = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('onVoicePrompt'));

    await messenger.handlePlatformMessage(
      'widget',
      data,
      (ByteData? reply) {},
    );

    await Future<void>.delayed(Duration.zero);
    expect(emitted, isTrue);

    await sub.cancel();
  });
}
