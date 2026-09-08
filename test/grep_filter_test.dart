import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/tools/grep_filter.dart';
import 'package:errand/tools/screen_tool.dart';

void main() {
  group('GrepFilter utility', () {
    const sampleText = '''
PORT=8080
DB_HOST=localhost
API_KEY=secret123
DEBUG=true
BACKUP_API_KEY=backup456
EMPTY=
''';

    test('filters lines with case-insensitive substring', () {
      final res = GrepFilter.filter(sampleText, 'api_key');
      expect(res, contains('API_KEY=secret123'));
      expect(res, contains('BACKUP_API_KEY=backup456'));
      expect(res, isNot(contains('PORT=8080')));
    });

    test('filters lines with regex', () {
      final res = GrepFilter.filter(sampleText, r'BACKUP_API_KEY=\w+');
      expect(res, contains('BACKUP_API_KEY=backup456'));
      expect(res, isNot(contains('PORT=8080')));
      expect(res.split('\n').any((l) => l == 'API_KEY=secret123'), isFalse);
    });

    test('falls back gracefully to literal match on invalid regex syntax', () {
      const text = 'foo [bar] baz\nhello (world)';
      final res1 = GrepFilter.filter(text, '[');
      expect(res1, contains('foo [bar] baz'));

      final res2 = GrepFilter.filter(text, '(world');
      expect(res2, contains('hello (world)'));
    });

    test('formats matching lines with line numbers when requested', () {
      final res = GrepFilter.filter(sampleText, 'DB_HOST', withLineNumbers: true);
      expect(res, contains('Line 2: DB_HOST=localhost'));
    });

    test('preserves optional header', () {
      final res = GrepFilter.filter(
        sampleText,
        'PORT',
        header: 'File: .env',
      );
      expect(res, startsWith('File: .env\nPORT=8080'));
    });

    test('returns honest message when no lines match', () {
      final res = GrepFilter.filter(sampleText, 'NON_EXISTENT');
      expect(res, equals('[No lines matched grep: "NON_EXISTENT"]'));
    });

    test('returns original text when grep is empty or whitespace', () {
      expect(GrepFilter.filter(sampleText, ''), equals(sampleText));
      expect(GrepFilter.filter(sampleText, '   '), equals(sampleText));
    });
  });

  group('readTool with grep', () {
    late Directory tempDir;
    late WorkingDirectory workspace;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_grep_test_');
      workspace = WorkingDirectory(tempDir);

      final file = File('${tempDir.path}/app.log');
      await file.writeAsString('''
2026-09-08 01:00:00 [INFO] Server started
2026-09-08 01:01:00 [WARN] High memory usage
2026-09-08 01:02:00 [ERROR] Connection timed out: DB_TIMEOUT
2026-09-08 01:03:00 [INFO] Heartbeat OK
2026-09-08 01:04:00 [ERROR] Failed to write record: DISK_FULL
''');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('reads and filters lines using regex with line numbers', () async {
      final tool = readTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'read_1',
          name: 'read',
          arguments: {
            'path': 'app.log',
            'grep': r'\[ERROR\]',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('File: '));
      expect(res.output, contains('Line 3: 2026-09-08 01:02:00 [ERROR] Connection timed out: DB_TIMEOUT'));
      expect(res.output, contains('Line 5: 2026-09-08 01:04:00 [ERROR] Failed to write record: DISK_FULL'));
      expect(res.output, isNot(contains('[INFO] Server started')));
    });

    test('returns not-found message when grep has no matches', () async {
      final tool = readTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'read_2',
          name: 'read',
          arguments: {
            'path': 'app.log',
            'grep': 'FATAL_CRASH',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('[No lines matched grep: "FATAL_CRASH"]'));
    });
  });

  group('listTool and findTool with grep', () {
    late Directory tempDir;
    late WorkingDirectory workspace;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_list_grep_test_');
      workspace = WorkingDirectory(tempDir);

      await File('${tempDir.path}/main.dart').create();
      await File('${tempDir.path}/app.dart').create();
      await File('${tempDir.path}/notes.txt').create();
      await Directory('${tempDir.path}/src').create();
      await File('${tempDir.path}/src/service.dart').create();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('listTool filters entries by grep regex', () async {
      final tool = listTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'list_1',
          name: 'list',
          arguments: {
            'path': '.',
            'grep': r'\.dart$',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('app.dart'));
      expect(res.output, contains('main.dart'));
      expect(res.output, isNot(contains('notes.txt')));
    });

    test('findTool filters results by grep pattern', () async {
      final tool = findTool(workspace);
      final res = await tool.handler(
        const ToolCall(
          id: 'find_1',
          name: 'find',
          arguments: {
            'path': '.',
            'pattern': '*',
            'grep': 'service',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('service.dart'));
      expect(res.output, isNot(contains('notes.txt')));
    });
  });

  group('screenTool with grep', () {
    test('filters outline lines by grep while keeping screen header', () async {
      final mock = _MockScreenA11yService();
      final tool = screenTool(service: mock);

      final res = await tool.handler(
        const ToolCall(
          id: 'screen_1',
          name: 'screen',
          arguments: {
            'action': 'read',
            'grep': r'Dark|Night',
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.output, contains('Screen: package=com.android.settings'));
      expect(res.output, contains('[2] Switch "Dark theme"'));
      expect(res.output, isNot(contains('[1] Button "Display"')));
      expect(res.output, isNot(contains('[3] Button "Sound"')));
    });
  });
}

class _MockScreenA11yService extends A11yService {
  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<bool> isRestricted() async => false;

  @override
  Future<Map<String, dynamic>> readScreen({
    int maxNodes = 300,
    bool full = false,
    bool probe = false,
  }) async {
    return {
      'ok': true,
      'outline': '''Screen: package=com.android.settings viewport=1080x2400
[1] Button "Display" @10,50 100x40
[2] Switch "Dark theme" [checked] @10,100 200x50
[3] Button "Sound" @10,160 100x40''',
    };
  }
}
