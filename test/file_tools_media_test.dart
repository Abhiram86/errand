import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/tools/file_tools.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('errand_media_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('1x1 png reads as an image content part with a data URL', () async {
    // Minimal valid PNG (1x1 transparent).
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
      'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    final file = File('${tempDir.path}/photo.png')..writeAsBytesSync(png);
    expect(file.existsSync(), isTrue);

    final tool = readTool(WorkingDirectory(tempDir));
    final result = await tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': 'photo.png'}),
    );

    expect(result.ok, isTrue);
    expect(result.contentParts, isNotNull);
    final part = result.contentParts!.single;
    expect(part['type'], 'image_url');
    expect(
      (part['image_url'] as Map)['url'],
      startsWith('data:image/png;base64,'),
    );
    expect(result.output, contains('image file loaded'));
  });

  test('mp3 reads as input_audio with the format tag', () async {
    File('${tempDir.path}/clip.mp3').writeAsBytesSync([1, 2, 3]);

    final tool = readTool(WorkingDirectory(tempDir));
    final result = await tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': 'clip.mp3'}),
    );

    expect(result.ok, isTrue);
    final part = result.contentParts!.single;
    expect(part['type'], 'input_audio');
    expect((part['input_audio'] as Map)['format'], 'mp3');
  });

  test('mp4 reads as video_url', () async {
    File('${tempDir.path}/clip.mp4').writeAsBytesSync([1, 2, 3]);

    final tool = readTool(WorkingDirectory(tempDir));
    final result = await tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': 'clip.mp4'}),
    );

    expect(result.ok, isTrue);
    expect(result.contentParts!.single['type'], 'video_url');
  });

  test('refuses image when capability callback says unsupported', () async {
    File('${tempDir.path}/photo.png').writeAsBytesSync([1]);
    final tool = readTool(
      WorkingDirectory(tempDir),
      supportsInput: (modality) => modality != 'image',
    );
    final result = await tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': 'photo.png'}),
    );

    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('does not support image'));
  });

  test('null capability (unknown endpoint) allows the attempt', () async {
    File('${tempDir.path}/photo.png').writeAsBytesSync([1]);
    bool called = false;
    final tool = readTool(
      WorkingDirectory(tempDir),
      supportsInput: (modality) {
        called = true;
        return true;
      },
    );
    final result = await tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': 'photo.png'}),
    );
    expect(called, isTrue);
    expect(result.ok, isTrue);
  });
}
