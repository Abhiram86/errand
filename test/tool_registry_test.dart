import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handy_flutter/agent/tool.dart';
import 'package:handy_flutter/agent/tool_registry.dart';
import 'package:handy_flutter/tools/file_tools.dart';

void main() {
  test('default registry exposes the core file tools', () {
    final registry = ToolRegistry.defaults(currentDir: Directory('/'));
    final names = registry.all.map((t) => t.name).toList();
    expect(names, containsAll(['read', 'list']));
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
}
