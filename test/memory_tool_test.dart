import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/memory_service.dart';
import 'package:errand/tools/memory_tool.dart';

void main() {
  late ErrandDatabase db;
  late MemoryService service;
  late Tool tool;

  setUp(() {
    db = ErrandDatabase.inMemory();
    service = MemoryService(db: db);
    tool = memoryTool(
      memoryService: service,
      currentConversationId: 'test_conv_123',
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('memoryTool - create', () {
    test('creates a valid memory and returns success payload', () async {
      final call = ToolCall(
        id: 'c1',
        name: 'memory',
        arguments: {
          'action': 'create',
          'about': 'User editor preferences and keybindings',
          'description': 'User prefers VS Code with vim keybindings and dark theme.',
          'keywords': ['editor', 'vscode', 'vim'],
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Saved memory [mem_'));
      expect(result.output, contains('About: User editor preferences and keybindings'));
      expect(result.output, contains('Description: User prefers VS Code with vim keybindings and dark theme.'));
      expect(result.output, contains('Keywords: editor, vscode, vim'));
    });

    test('fails on missing about or description', () async {
      final call = ToolCall(
        id: 'c2',
        name: 'memory',
        arguments: {
          'action': 'create',
          'about': '',
          'description': 'some desc',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('about'));
    });

    test('fails on invalid keywords (sentence format)', () async {
      final call = ToolCall(
        id: 'c3',
        name: 'memory',
        arguments: {
          'action': 'create',
          'about': 'reading_goal',
          'description': 'Read 20 books per year.',
          'keywords': ['I like to read fiction.'],
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('sentence'));
    });
  });

  group('memoryTool - read', () {
    test('retrieves full memory details by id', () async {
      final created = await service.create(
        about: 'Coffee order and milk preference',
        description: 'Prefers oat milk cortado with no sugar.',
        keywords: ['coffee', 'drinks'],
      );

      final call = ToolCall(
        id: 'c4',
        name: 'memory',
        arguments: {
          'action': 'read',
          'id': created.id,
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Memory [${created.id}]'));
      expect(result.output, contains('About: Coffee order and milk preference'));
      expect(result.output, contains('Description: Prefers oat milk cortado with no sugar.'));
      expect(result.output, contains('Keywords: coffee, drinks'));
      expect(result.output, contains('Updated:'));
    });

    test('fails when id is missing or non-existent', () async {
      final callMissing = ToolCall(
        id: 'c5',
        name: 'memory',
        arguments: {'action': 'read'},
      );
      final resMissing = await tool.handler(callMissing);
      expect(resMissing.ok, isFalse);

      final callNotFound = ToolCall(
        id: 'c6',
        name: 'memory',
        arguments: {'action': 'read', 'id': 'unknown_id'},
      );
      final resNotFound = await tool.handler(callNotFound);
      expect(resNotFound.ok, isFalse);
      expect(resNotFound.errorMessage, contains('not found'));
    });
  });

  group('memoryTool - find', () {
    test('returns top candidates matching query with only id and about', () async {
      await service.create(
        about: 'Python data science stack and tools',
        description: 'Uses python for data analysis.',
        keywords: ['python', 'data'],
      );
      await service.create(
        about: 'Rust systems programming tools',
        description: 'Uses rust for systems programming.',
        keywords: ['rust', 'systems'],
      );

      final call = ToolCall(
        id: 'c7',
        name: 'memory',
        arguments: {
          'action': 'find',
          'query': 'python analysis',
          'k': 1,
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('- [mem_'));
      expect(result.output, contains('Python data science stack and tools'));
      expect(result.output.contains('Rust systems programming tools'), isFalse);
      // Ensure descriptions are NOT returned in find
      expect(result.output.contains('Uses python for data analysis.'), isFalse);
    });

    test('returns clear message when no memories match', () async {
      final call = ToolCall(
        id: 'c8',
        name: 'memory',
        arguments: {
          'action': 'find',
          'query': 'completely_unrelated_xyz',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, 'No memories found.');
    });
  });

  group('memoryTool - edit', () {
    test('edits fields successfully', () async {
      final created = await service.create(
        about: 'Current residential city and state',
        description: 'User currently lives in Seattle.',
        keywords: ['location', 'city'],
      );

      final call = ToolCall(
        id: 'c9',
        name: 'memory',
        arguments: {
          'action': 'edit',
          'id': created.id,
          'description': 'User currently lives in San Francisco.',
          'keywords': ['location', 'city', 'california'],
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isTrue);
      expect(result.output, contains('Updated memory [${created.id}]'));
      expect(result.output, contains('About: Current residential city and state'));
      expect(result.output, contains('Description: User currently lives in San Francisco.'));
      expect(result.output, contains('Keywords: location, city, california'));
    });

    test('fails if id does not exist', () async {
      final call = ToolCall(
        id: 'c10',
        name: 'memory',
        arguments: {
          'action': 'edit',
          'id': 'mem_not_existing',
          'description': 'New desc',
        },
      );

      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('not found'));
    });
  });

  group('memoryTool - action routing by tool name', () {
    test('deduces action from memory.find and memory_find names', () async {
      await service.create(
        about: 'Pet cat name and characteristics',
        description: 'Pet cat is named Luna.',
        keywords: ['pets', 'cat'],
      );

      final callDot = ToolCall(
        id: 'c11',
        name: 'memory.find',
        arguments: {'query': 'cat'},
      );
      final resDot = await tool.handler(callDot);
      expect(resDot.ok, isTrue);
      expect(resDot.output, contains('Pet cat name and characteristics'));

      final callUnder = ToolCall(
        id: 'c12',
        name: 'memory_find',
        arguments: {'query': 'cat'},
      );
      final resUnder = await tool.handler(callUnder);
      expect(resUnder.ok, isTrue);
      expect(resUnder.output, contains('Pet cat name and characteristics'));
    });
  });

  group('ToolRegistry execution', () {
    test('ToolRegistry routes memory calls and aliases to memoryTool', () async {
      final registry = ToolRegistry.defaults(
        currentDir: Directory.systemTemp,
        memoryService: service,
        currentConversationId: 'test_conv_registry',
      );

      // Verify tool registered
      final tools = registry.all;
      expect(tools.any((t) => t.name == 'memory'), isTrue);

      // Execute via memory
      final callCreate = ToolCall(
        id: 'r1',
        name: 'memory',
        arguments: {
          'action': 'create',
          'about': 'ToolRegistry integration check',
          'description': 'Testing registry dispatch.',
          'keywords': ['test'],
        },
      );
      final resCreate = await registry.execute(callCreate);
      expect(resCreate.ok, isTrue);
      expect(resCreate.output, contains('Saved memory [mem_'));

      // Execute via memory.find alias
      final callFind = ToolCall(
        id: 'r2',
        name: 'memory.find',
        arguments: {'query': 'registry'},
      );
      final resFind = await registry.execute(callFind);
      expect(resFind.ok, isTrue);
      expect(resFind.output, contains('ToolRegistry integration check'));
    });
  });
}
