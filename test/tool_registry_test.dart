import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/types/tool.dart';

void main() {
  test('default registry exposes the core file tools', () {
    final registry = ToolRegistry.defaults(currentDir: Directory('/'));
    final names = registry.all.map((t) => t.name).toList();
    expect(names, containsAll(['read', 'workspace', 'websearch', 'webfetch']));
  });

  test('unknown tool returns a failure result', () async {
    final registry = ToolRegistry.defaults(currentDir: Directory('/'));
    const call = ToolCall(id: '1', name: 'nope', arguments: {});
    final result = await registry.execute(call);
    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('Unknown tool'));
  });

  test('tool call arguments use the LLM JSON-string wire format', () {
    const call = ToolCall(
      id: '1',
      name: 'read',
      arguments: {'path': 'README.md'},
    );

    final function = call.toJson()['function'] as Map<String, dynamic>;
    expect(function['arguments'], '{"path":"README.md"}');
  });

  test('tool validation metadata stays outside the model schema', () {
    final tool = Tool(
      name: 'mutate',
      description: 'Test mutation tool',
      parameters: const {'type': 'object'},
      requiresValidation: true,
      handler: (call) async =>
          ToolCallResult(id: call.id, ok: true, output: 'ok'),
    );

    expect(tool.requiresValidation, isTrue);
    final function = tool.toJson()['function'] as Map<String, dynamic>;
    expect(function.containsKey('requiresValidation'), isFalse);
  });

  test('read rejects paths outside the workspace and oversized ranges', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_workspace');
    final outside = File(
      '${workspace.parent.path}/errand_outside_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await outside.writeAsString('outside');
    addTearDown(() async {
      await workspace.delete(recursive: true);
      await outside.delete();
    });

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final outsideResult = await registry.execute(
      ToolCall(id: 'outside', name: 'read', arguments: {'path': outside.path}),
    );
    final oversizedResult = await registry.execute(
      ToolCall(
        id: 'large',
        name: 'read',
        arguments: {'path': 'missing.txt', 'length': kMaxReadBytes + 1},
      ),
    );

    expect(outsideResult.ok, isFalse);
    expect(outsideResult.errorMessage, contains('outside the workspace'));
    expect(oversizedResult.ok, isFalse);
    expect(oversizedResult.errorMessage, contains('maximum readable range'));
  });

  test('find matches shell-style file patterns and directory types', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_find');
    final nested = Directory('${workspace.path}/nested');
    final deeper = Directory('${nested.path}/deeper');
    await nested.create();
    await deeper.create();
    await File('${workspace.path}/report.pdf').writeAsString('pdf');
    await File('${nested.path}/nested.pdf').writeAsString('pdf');
    await File('${deeper.path}/deep.pdf').writeAsString('pdf');
    await File('${nested.path}/notes.txt').writeAsString('text');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final files = await registry.execute(
      const ToolCall(
        id: 'find-files',
        name: 'workspace',
        arguments: {
          'action': 'find',
          'path': '.',
          'pattern': '*.pdf',
          'type': 'file',
        },
      ),
    );
    final dirs = await registry.execute(
      const ToolCall(
        id: 'find-dirs',
        name: 'workspace',
        arguments: {
          'action': 'find',
          'path': '.',
          'pattern': 'nest*',
          'type': 'dir',
        },
      ),
    );

    expect(files.ok, isTrue);
    expect(files.output, contains('report.pdf'));
    expect(files.output, contains('nested.pdf'));
    expect(files.output, contains('deep.pdf'));
    expect(dirs.ok, isTrue);
    expect(dirs.output, contains('nested'));
  });

  test('find accepts regex-style patterns too', () async {
    // Regression: the pattern was glob-only, so a regex like `\.pdf$` was
    // escaped literally (backslash + dollar) and matched nothing — the
    // agent got "found 0 match(es)" even though PDFs existed.
    final workspace = await Directory.systemTemp.createTemp('errand_find_re');
    await File('${workspace.path}/report.pdf').writeAsString('pdf');
    await File('${workspace.path}/notes.txt').writeAsString('text');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final result = await registry.execute(
      const ToolCall(
        id: 'find-regex',
        name: 'workspace',
        arguments: {
          'action': 'find',
          'path': '.',
          'pattern': r'\.pdf$',
          'type': 'file',
        },
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('report.pdf'));
    expect(result.output, isNot(contains('notes.txt')));
  });

  test('find max_depth prunes deeper directories', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_depth');
    final levelOne = Directory('${workspace.path}/one');
    final levelTwo = Directory('${levelOne.path}/two');
    final levelThree = Directory('${levelTwo.path}/three');
    await levelThree.create(recursive: true);
    await File('${levelThree.path}/deep.pdf').writeAsString('pdf');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final result = await registry.execute(
      const ToolCall(
        id: 'depth',
        name: 'workspace',
        arguments: {
          'action': 'find',
          'path': '.',
          'pattern': '*.pdf',
          'max_depth': 2,
        },
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, isNot(contains('deep.pdf')));
    expect(result.output, contains('max depth: 2'));
  });

  test('cd changes the shared base for subsequent relative searches', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_cd');
    final nested = Directory('${workspace.path}/nested');
    await nested.create();
    await File('${nested.path}/inside.pdf').writeAsString('pdf');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final changed = await registry.execute(
      const ToolCall(
        id: 'cd',
        name: 'workspace',
        arguments: {'action': 'cd', 'path': 'nested'},
      ),
    );
    final found = await registry.execute(
      const ToolCall(
        id: 'find-after-cd',
        name: 'workspace',
        arguments: {'action': 'find', 'path': '.', 'pattern': '*.pdf'},
      ),
    );

    expect(changed.ok, isTrue);
    expect(changed.output, contains('Changed current directory'));
    expect(found.ok, isTrue);
    expect(found.output, contains('inside.pdf'));
    expect(found.output, contains(nested.path));
  });

  test('read supports file:// URIs and accepts double num args from LLM JSON', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_file_uri');
    final file = File('${workspace.path}/sample.txt');
    await file.writeAsString('Hello file URI content');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final result = await registry.execute(
      ToolCall(
        id: 'read-uri',
        name: 'read',
        arguments: {
          'path': 'file://${file.path}',
          'offset': 0.0,
          'length': 1024.0,
        },
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('Hello file URI content'));
  });

  test('find matches pattern containing subpaths', () async {
    final workspace = await Directory.systemTemp.createTemp('errand_subpath');
    final sub = Directory('${workspace.path}/sub');
    await sub.create();
    await File('${sub.path}/target.txt').writeAsString('text');
    await File('${workspace.path}/other.txt').writeAsString('text');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final result = await registry.execute(
      const ToolCall(
        id: 'find-sub',
        name: 'workspace',
        arguments: {
          'action': 'find',
          'path': '.',
          'pattern': 'sub/*.txt',
        },
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('target.txt'));
    expect(result.output, isNot(contains('other.txt')));
  });

  test('ToolRegistry.dispose triggers tool cleanup', () {
    var disposed = false;
    final tool = Tool(
      name: 'cleanup',
      description: 'test cleanup',
      parameters: const {},
      handler: (c) async => ToolCallResult(id: c.id, ok: true, output: ''),
      onDispose: () => disposed = true,
    );

    final registry = ToolRegistry([tool]);
    expect(disposed, isFalse);
    registry.dispose();
    expect(disposed, isTrue);
  });
}
