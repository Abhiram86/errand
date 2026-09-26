import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/types/tool.dart';

/// Regression tests for the staged-file gate (C3): absolute paths outside
/// the workspace are allowed only inside the app's real staged dirs
/// (`<cache>/file_picker`, `<cache>/screenshots`), resolved post-symlink.
/// A planted path merely containing the magic segment must be rejected.
void main() {
  late Directory workspaceRoot;
  late Directory fakeCache;
  late Directory planted;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    workspaceRoot = await Directory.systemTemp.createTemp('ws_root');
    fakeCache = await Directory.systemTemp.createTemp('app_cache');
    planted = await Directory.systemTemp.createTemp('planted');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory' ||
            call.method == 'getApplicationCacheDirectory') {
          return fakeCache.path;
        }
        return null;
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await workspaceRoot.delete(recursive: true);
    await fakeCache.delete(recursive: true);
    await planted.delete(recursive: true);
  });

  Future<ToolCallResult> readAbs(String absPath) {
    final tool = readTool(WorkingDirectory(workspaceRoot));
    return tool.handler(
      ToolCall(id: 'c1', name: 'read', arguments: {'path': absPath}),
    );
  }

  test('real staged file_picker path is readable by absolute path', () async {
    final dir = Directory('${fakeCache.path}/file_picker')..createSync();
    File('${dir.path}/picked.txt').writeAsStringSync('picked-content');

    final result = await readAbs('${dir.path}/picked.txt');
    expect(result.ok, isTrue);
    expect(result.output, contains('picked-content'));
  });

  test('planted magic-segment path outside staged dirs is rejected', () async {
    final dir = Directory('${planted.path}/anything/cache/file_picker')
      ..createSync(recursive: true);
    File('${dir.path}/secret.txt').writeAsStringSync('top-secret');

    final result = await readAbs('${dir.path}/secret.txt');
    expect(result.ok, isFalse);
  });

  test('symlink inside staged dir pointing outside is rejected', () async {
    final staged = Directory('${fakeCache.path}/file_picker')..createSync();
    final outside =
        File('${planted.path}/outside.txt')..writeAsStringSync('outside');
    Link('${staged.path}/link.txt').createSync(outside.path);

    final result = await readAbs('${staged.path}/link.txt');
    expect(result.ok, isFalse);
  });
}
