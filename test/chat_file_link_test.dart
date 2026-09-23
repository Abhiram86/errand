import 'dart:io';

import 'package:errand/widgets/bubbles/bubble_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveChatFileLink', () {
    late Directory tempDir;
    late Directory docsDir;
    late Directory scratchDir;
    late String realFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_link_test_');
      docsDir = Directory('${tempDir.path}/Documents/Errand');
      scratchDir = Directory('${tempDir.path}/scratch');
      await docsDir.create(recursive: true);
      await scratchDir.create(recursive: true);
      realFile = '${docsDir.path}/hello_world.txt';
      File(realFile).writeAsStringSync('hello');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    List<String> roots() => [docsDir.path, scratchDir.path];

    test('resolves file:// links under allowed roots', () {
      final url = Uri.file(realFile).toString();
      expect(resolveChatFileLink(url, roots()), equals(realFile));
    });

    test('rejects traversal outside roots', () {
      final outside = File('${tempDir.path}/secret.txt')..writeAsStringSync('x');
      expect(
        resolveChatFileLink(Uri.file(outside.path).toString(), roots()),
        isNull,
      );
      expect(
        resolveChatFileLink('file://${docsDir.path}/../secret.txt', roots()),
        isNull,
      );
    });

    test('rejects non-file schemes and missing files', () {
      expect(resolveChatFileLink('https://example.com/a.md', roots()), isNull);
      expect(
        resolveChatFileLink(
          Uri.file('${docsDir.path}/nope.md').toString(),
          roots(),
        ),
        isNull,
      );
      expect(resolveChatFileLink('not a url at all', roots()), isNull);
    });
  });
}
