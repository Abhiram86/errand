import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handy_flutter/agent/tool.dart';
import 'package:handy_flutter/agent/tool_registry.dart';
import 'package:handy_flutter/tools/file_tools.dart';

void main() {
  test('default registry exposes the core file tools', () {
    final registry = ToolRegistry.defaults(currentDir: Directory('/'));
    final names = registry.all.map((t) => t.name).toList();
    expect(
      names,
      containsAll(['read', 'list', 'find', 'cd', 'websearch', 'webfetch']),
    );
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

  test('read rejects paths outside the workspace and oversized ranges', () async {
    final workspace = await Directory.systemTemp.createTemp('handy_workspace');
    final outside = File(
      '${workspace.parent.path}/handy_outside_${DateTime.now().microsecondsSinceEpoch}.txt',
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
    final workspace = await Directory.systemTemp.createTemp('handy_find');
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
        name: 'find',
        arguments: {'path': '.', 'pattern': '*.pdf', 'type': 'file'},
      ),
    );
    final dirs = await registry.execute(
      const ToolCall(
        id: 'find-dirs',
        name: 'find',
        arguments: {'path': '.', 'pattern': 'nest*', 'type': 'dir'},
      ),
    );

    expect(files.ok, isTrue);
    expect(files.output, contains('report.pdf'));
    expect(files.output, contains('nested.pdf'));
    expect(files.output, contains('deep.pdf'));
    expect(dirs.ok, isTrue);
    expect(dirs.output, contains('nested'));
  });

  test('find max_depth prunes deeper directories', () async {
    final workspace = await Directory.systemTemp.createTemp('handy_depth');
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
        name: 'find',
        arguments: {'path': '.', 'pattern': '*.pdf', 'max_depth': 2},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, isNot(contains('deep.pdf')));
    expect(result.output, contains('max depth: 2'));
  });

  test('cd changes the shared base for subsequent relative searches', () async {
    final workspace = await Directory.systemTemp.createTemp('handy_cd');
    final nested = Directory('${workspace.path}/nested');
    await nested.create();
    await File('${nested.path}/inside.pdf').writeAsString('pdf');
    addTearDown(() => workspace.delete(recursive: true));

    final registry = ToolRegistry.defaults(currentDir: workspace);
    final changed = await registry.execute(
      const ToolCall(id: 'cd', name: 'cd', arguments: {'path': 'nested'}),
    );
    final found = await registry.execute(
      const ToolCall(
        id: 'find-after-cd',
        name: 'find',
        arguments: {'path': '.', 'pattern': '*.pdf'},
      ),
    );

    expect(changed.ok, isTrue);
    expect(changed.output, contains('Changed current directory'));
    expect(found.ok, isTrue);
    expect(found.output, contains('inside.pdf'));
    expect(found.output, contains(nested.path));
  });
}
