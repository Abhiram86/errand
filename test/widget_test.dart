import 'package:flutter_test/flutter_test.dart';
import 'package:handy_flutter/agent/tool.dart';
import 'package:handy_flutter/agent/tool_registry.dart';

import 'dart:io';

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
}
