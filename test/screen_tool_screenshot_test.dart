import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/screen_tool.dart';

void main() {
  group('screenTool screenshot action', () {
    test('captures screenshot and returns path and image in contentParts', () async {
      final mock = _MockScreenshotA11yService();
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_1',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
            'quality': 'sd',
            'temp': true,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(
        res.output,
        'Captured SD screenshot (/data/user/0/cache/screenshots/shot.jpg, 720x1560, 48 KB, temporary cache).',
      );
      expect(
        res.output,
        isNot(contains('The image is attached to this conversation turn for visual analysis.')),
      );
      expect(res.contentParts, isNotNull);
      expect(res.contentParts!.length, 1);
      expect(res.contentParts!.first['type'], 'image_url');
      final imgUrl = (res.contentParts!.first['image_url'] as Map<String, dynamic>)['url'] as String;
      expect(imgUrl, startsWith('data:image/jpeg;base64,'));
      expect(mock.lastQuality, 'sd');
      expect(mock.lastTemp, isTrue);
    });

    test('defaults quality to sd when temp is true and quality is omitted', () async {
      final mock = _MockScreenshotA11yService();
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_default_sd',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
            'temp': true,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(mock.lastQuality, 'sd');
      expect(res.output, contains('Captured SD screenshot'));
      expect(res.output, contains('/data/user/0/cache/screenshots/shot.jpg'));
    });

    test('defaults quality to hd when temp is false and quality is omitted', () async {
      final mock = _MockScreenshotA11yService();
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_default_hd',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
            'temp': false,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(mock.lastQuality, 'hd');
      expect(res.output, contains('Captured HD screenshot'));
      expect(res.output, contains('/storage/emulated/0/Pictures/Screenshots/shot.jpg'));
      expect(res.output, contains('Pictures/Screenshots'));
    });

    test('captures screenshot with temp: false and explicit quality', () async {
      final mock = _MockScreenshotA11yService();
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_2',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
            'quality': 'sd',
            'temp': false,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Pictures/Screenshots'));
      expect(res.output, contains('Captured SD screenshot'));
      expect(mock.lastQuality, 'sd');
      expect(mock.lastTemp, isFalse);
    });

    test('fails honestly when accessibility returns an error', () async {
      final mock = _MockScreenshotA11yService()
        ..shouldFail = true
        ..failureMessage =
            'SECURE_WINDOW: Screen contains secure or protected content and cannot be captured.';
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_fail',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
          },
        ),
      );

      expect(res.ok, isFalse);
      expect(res.errorMessage, contains('SECURE_WINDOW'));
    });

    test('fails with guidance when accessibility is disabled', () async {
      final mock = _MockScreenshotA11yService()..enabled = false;
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'shot_disabled',
          name: 'screen',
          arguments: {
            'action': 'screenshot',
          },
        ),
      );

      expect(res.ok, isFalse);
      expect(res.errorMessage, contains('Screen access is currently off'));
    });

    test('file read tool resolves and reads screenshot file from cache', () async {
      final tempRoot = await Directory.systemTemp.createTemp('screen_read_test');
      try {
        final cacheDir = Directory('${tempRoot.path}/cache/screenshots')..createSync(recursive: true);
        final shotFile = File('${cacheDir.path}/screenshot_test.jpg');
        final jpegBytes = base64Decode(
          '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP/////////////////////////////////'
          '/////////////////////////////////////////////////////wgALCAABAAEB'
          'AREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=',
        );
        shotFile.writeAsBytesSync(jpegBytes);

        final workspaceDir = Directory('${tempRoot.path}/workspace')..createSync();
        final fileTool = readTool(WorkingDirectory(workspaceDir));

        final result = await fileTool.handler(
          ToolCall(
            id: 'file_read_shot',
            name: 'read',
            arguments: {'path': shotFile.path},
          ),
        );

        expect(result.ok, isTrue);
        expect(result.contentParts, isNotNull);
        expect(result.contentParts!.first['type'], 'image_url');
      } finally {
        await tempRoot.delete(recursive: true);
      }
    });
  });
}

class _MockScreenshotA11yService extends A11yService {
  bool enabled = true;
  bool restricted = false;
  bool shouldFail = false;
  String failureMessage = 'Screenshot error';

  String? lastQuality;
  bool? lastTemp;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> isRestricted() async => restricted;

  @override
  Future<Map<String, dynamic>> takeScreenshot({
    String? quality,
    bool temp = true,
  }) async {
    final effectiveQuality = (quality == 'hd' || quality == 'sd')
        ? quality!
        : (temp ? 'sd' : 'hd');
    lastQuality = effectiveQuality;
    lastTemp = temp;

    if (shouldFail) {
      return {
        'ok': false,
        'error': 'CAPTURE_FAILED',
        'message': failureMessage,
      };
    }

    return {
      'ok': true,
      'path': temp
          ? '/data/user/0/cache/screenshots/shot.jpg'
          : '/storage/emulated/0/Pictures/Screenshots/shot.jpg',
      'width': effectiveQuality == 'sd' ? 720 : 1080,
      'height': effectiveQuality == 'sd' ? 1560 : 2340,
      'size_kb': effectiveQuality == 'sd' ? 48 : 190,
      'quality': effectiveQuality,
      'base64': 'AQIDBA==',
      'message': 'Captured screenshot successfully',
    };
  }
}
