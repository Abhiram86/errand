import '../agent/tool.dart';
import '../services/memory_service.dart';
import '../types/tool.dart';

/// Creates the `memory` tool, exposing structured persistent user memory functions:
/// - `find` (`memory.find`): search candidate memories (returns only id and about)
/// - `read` (`memory.read`): retrieve complete details of a memory by id
/// - `create` (`memory.create`): save a new memory (about, description, keywords)
/// - `edit` (`memory.edit`): update an existing memory by id
Tool memoryTool({
  MemoryService? memoryService,
  String? currentConversationId,
}) {
  return Tool(
    name: 'memory',
    description:
        'Structured user memory tool group for persistent user preferences, '
        'facts, and guidelines across conversations. '
        'Functions: '
        'find (search candidate memories by query or timestamp; returns ONLY id and about), '
        'read (retrieve full details for a memory by id), '
        'create (save a new memory with about, description, keywords), '
        'edit (update an existing memory by id). '
        'Usage policy: Retrieval is optional. Call find ONLY when user-specific context from '
        'previous conversations is materially relevant and not present in the current chat. '
        'Write policy: Creating/editing memory must NEVER happen automatically. Only write when '
        'the user explicitly asks to remember something, or after the user explicitly confirms '
        'your suggestion to remember it.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['find', 'read', 'create', 'edit'],
          'description':
              'The memory function to execute: '
              'find (memory.find), read (memory.read), create (memory.create), or edit (memory.edit).',
        },
        'query': {
          'type': 'string',
          'description':
              'Search query for action:"find". Matched approximately against about, keywords, and description.',
        },
        'timestamp': {
          'type': 'string',
          'description':
              'Optional date or timestamp filter for action:"find" (e.g. "2026-09-01", "after:2026-01-01", "before:2026-09-14").',
        },
        'k': {
          'type': 'integer',
          'default': 3,
          'description':
              'Maximum number of candidate memories to return for action:"find" (default 3).',
        },
        'id': {
          'type': 'string',
          'description':
              'Unique memory identifier for action:"read" or action:"edit".',
        },
        'about': {
          'type': 'string',
          'description':
              'Concise one-line natural language summary of what this memory is about (NOT a generic title like "Notes" or "Preferences", and NOT snake_case; e.g. "Prefers Python with pytest and strict typing", "Office Wi-Fi connection info", "AMOLED dark mode UI preference").',
        },
        'description': {
          'type': 'string',
          'description':
              'Small but information-rich description giving context to understand/steer user intent for action:"create" or action:"edit".',
        },
        'keywords': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Array of short generic keywords (max 10 concepts, not sentences) for action:"create" or action:"edit".',
        },
      },
      'required': ['action'],
    },
    handler: (call) => _handleMemoryCall(
      call,
      memoryService ?? MemoryService.instance,
      currentConversationId,
    ),
  );
}

String _actionFromToolName(String name) {
  if (name.endsWith('.find') || name.endsWith('_find')) return 'find';
  if (name.endsWith('.read') || name.endsWith('_read')) return 'read';
  if (name.endsWith('.create') || name.endsWith('_create')) return 'create';
  if (name.endsWith('.edit') || name.endsWith('_edit')) return 'edit';
  return 'find';
}

Future<ToolCallResult> _handleMemoryCall(
  ToolCall call,
  MemoryService service,
  String? currentConversationId,
) async {
  final rawAction = call.arguments['action']?.toString().trim();
  final action = (rawAction != null && rawAction.isNotEmpty)
      ? rawAction
      : _actionFromToolName(call.name);

  switch (action) {
    case 'find':
      return _handleFind(call, service);
    case 'read':
      return _handleRead(call, service);
    case 'create':
      return _handleCreate(call, service, currentConversationId);
    case 'edit':
      return _handleEdit(call, service);
    default:
      return ToolCallResult.failure(
        call.id,
        'Unsupported memory action "$action". Acceptable actions are: find, read, create, edit.',
      );
  }
}

Future<ToolCallResult> _handleFind(ToolCall call, MemoryService service) async {
  final query = call.arguments['query']?.toString();
  final timestamp = call.arguments['timestamp']?.toString();
  final rawK = call.arguments['k'];
  final int k = (rawK is int)
      ? rawK
      : (int.tryParse(rawK?.toString() ?? '') ?? 3);

  final results = await service.find(
    query: query,
    timestamp: timestamp,
    k: k,
  );

  if (results.isEmpty) {
    return ToolCallResult(id: call.id, ok: true, output: 'No memories found.');
  }

  final buffer = StringBuffer();
  for (final r in results) {
    buffer.writeln('- [${r.id}] ${r.about}');
  }
  return ToolCallResult(id: call.id, ok: true, output: buffer.toString().trimRight());
}

Future<ToolCallResult> _handleRead(ToolCall call, MemoryService service) async {
  final id = call.arguments['id']?.toString().trim() ?? '';
  if (id.isEmpty) {
    return ToolCallResult.failure(call.id, 'The "id" parameter is required for action:"read".');
  }

  final memory = await service.read(id);
  if (memory == null) {
    return ToolCallResult.failure(call.id, 'Memory with id "$id" not found.');
  }

  final buffer = StringBuffer()
    ..writeln('Memory [${memory.id}]')
    ..writeln('About: ${memory.about}')
    ..writeln('Description: ${memory.description}')
    ..writeln('Keywords: ${memory.keywords.join(', ')}')
    ..writeln('Updated: ${memory.updatedAt.toIso8601String()}');

  return ToolCallResult(id: call.id, ok: true, output: buffer.toString().trimRight());
}

Future<ToolCallResult> _handleCreate(
  ToolCall call,
  MemoryService service,
  String? currentConversationId,
) async {
  final about = call.arguments['about']?.toString().trim() ?? '';
  if (about.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'The "about" parameter is required for action:"create".',
    );
  }

  final description = call.arguments['description']?.toString().trim() ?? '';
  if (description.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'The "description" parameter is required for action:"create".',
    );
  }

  final rawKeywords = call.arguments['keywords'];
  List<String> keywords = const [];
  if (rawKeywords is List) {
    keywords = rawKeywords.map((e) => e.toString()).toList();
  } else if (rawKeywords != null) {
    return ToolCallResult.failure(
      call.id,
      'The "keywords" parameter must be an array of strings (max 10).',
    );
  }

  try {
    final memory = await service.create(
      about: about,
      description: description,
      keywords: keywords,
      sourceConversationId: currentConversationId,
    );

    final buffer = StringBuffer()
      ..writeln('Saved memory [${memory.id}]')
      ..writeln('About: ${memory.about}')
      ..writeln('Description: ${memory.description}')
      ..writeln('Keywords: ${memory.keywords.join(', ')}');

    return ToolCallResult(
      id: call.id,
      ok: true,
      output: buffer.toString().trimRight(),
    );
  } on ArgumentError catch (e) {
    return ToolCallResult.failure(call.id, e.message.toString());
  } catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to create memory: $e');
  }
}

Future<ToolCallResult> _handleEdit(ToolCall call, MemoryService service) async {
  final id = call.arguments['id']?.toString().trim() ?? '';
  if (id.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'The "id" parameter is required for action:"edit".',
    );
  }

  final about = call.arguments['about']?.toString();
  final description = call.arguments['description']?.toString();
  final rawKeywords = call.arguments['keywords'];

  List<String>? keywords;
  if (rawKeywords is List) {
    keywords = rawKeywords.map((e) => e.toString()).toList();
  } else if (rawKeywords != null) {
    return ToolCallResult.failure(
      call.id,
      'The "keywords" parameter must be an array of strings (max 10).',
    );
  }

  try {
    final updatedMemory = await service.edit(
      id: id,
      about: about,
      description: description,
      keywords: keywords,
    );

    final buffer = StringBuffer()
      ..writeln('Updated memory [${updatedMemory.id}]')
      ..writeln('About: ${updatedMemory.about}')
      ..writeln('Description: ${updatedMemory.description}')
      ..writeln('Keywords: ${updatedMemory.keywords.join(', ')}');

    return ToolCallResult(
      id: call.id,
      ok: true,
      output: buffer.toString().trimRight(),
    );
  } on ArgumentError catch (e) {
    return ToolCallResult.failure(call.id, e.message.toString());
  } catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to edit memory: $e');
  }
}
