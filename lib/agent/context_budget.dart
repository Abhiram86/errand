import 'dart:convert';

import '../types/message.dart';

/// Default native context window assumptions (in tokens).
const int kDefaultContextSizeTokens = 128000;

/// Head-clamp ceiling for a single tool result (in characters).
/// Prevents a single massive `read` or shell output from instantly blowing the budget.
const int kMaxToolResultChars = 32 * 1024;

/// Legacy character constants maintained for backward compatibility.
const int kContextWindowChars = 256 * 1024;
const int kContextSoftLimit = 200 * 1024;
const int kContextTarget = 110 * 1024;

const int _perMessageOverheadChars = 40;
const int _perMessageOverheadTokens = 10;
const String _truncationMarker = '\n[...truncated ';

/// Marker string used at the start of compacted context user messages.
const String kCompactedContextMarker = '[COMPACTED PREVIOUS CONTEXT & TOOL EXECUTION STATE]';

/// Represents the dynamic context budget computed from native model context limits.
class ContextBudget {
  /// The native context limit of the model in tokens (e.g. 128000, 200000, 1048576).
  final int contextSize;

  /// Dynamic reserved headroom for generation, reasoning, and tool schemas.
  /// Formulated as: min(16,000, 0.25 * contextSize).
  final int reservedTokens;

  /// Optional override threshold (useful for testing or constrained runs).
  final int? overrideThreshold;

  ContextBudget({required this.contextSize, this.overrideThreshold})
      : reservedTokens = computeReservedTokens(contextSize);

  /// Computes the dynamic reserved tokens headroom: min(16k tokens, 25% of ctx size).
  static int computeReservedTokens(int contextSize) {
    if (contextSize <= 0) return 4000;
    final quarter = (contextSize * 0.25).round();
    return quarter < 16000 ? quarter : 16000;
  }

  /// Theoretical native threshold: contextSize - reservedTokens (approx. 75% for models <= 64k).
  int get nativeCompactionThreshold => contextSize - reservedTokens;

  /// The usage threshold above which history must be compacted before the next step.
  /// Defaults to [nativeCompactionThreshold] (contextSize - reservedTokens).
  int get compactionThreshold => overrideThreshold ?? nativeCompactionThreshold;

  /// Target token budget after compaction or trimming.
  int get targetTokens => (compactionThreshold * 0.5).round();

  /// Whether the given estimated [currentTokens] requires compaction.
  bool shouldCompact(int currentTokens) => currentTokens > compactionThreshold;

  static final ContextBudget defaultBudget = ContextBudget(
    contextSize: kDefaultContextSizeTokens,
  );
}

// ---- Token Estimation Helpers ----------------------------------------------

/// Rough token estimation for text content (~3.8 characters per token).
int estimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  return (text.length / 3.8).ceil();
}

/// Estimates tokens contributed by a high-level [Message].
int estimateMessageTokens(Message message) {
  var tokens = estimateTextTokens(message.text) + _perMessageOverheadTokens;
  if (message is UserMessage && message.attachedUris.isNotEmpty) {
    tokens += estimateTextTokens(jsonEncode(message.attachedUris));
  }
  if (message is ToolMessage) {
    tokens += estimateTextTokens(message.tool.name);
    tokens += estimateTextTokens(jsonEncode(message.tool.args));
    tokens += estimateTextTokens(message.result);
    if (message.reasoning != null) {
      tokens += estimateTextTokens(message.reasoning!);
    }
    if (message.reasoningDetails.isNotEmpty) {
      tokens += estimateTextTokens(jsonEncode(message.reasoningDetails));
    }
  }
  if (message is ErrorMessage) {
    tokens += estimateTextTokens(message.error);
  }
  if (message is CompactedNoticeMessage && message.summary.isNotEmpty) {
    tokens += estimateTextTokens(message.summary);
  }
  return tokens;
}

/// Estimates tokens for a full [Message] history.
int estimateHistoryTokens(List<Message> history) =>
    history.fold(0, (sum, m) => sum + estimateMessageTokens(m));

/// Estimates tokens for a low-level LLM message map (`role`, `content`, `tool_calls`).
int estimateLlmMessageTokens(Map<String, dynamic> message) {
  var tokens = _perMessageOverheadTokens;
  final role = message['role'];
  if (role is String) tokens += 2;

  final content = message['content'];
  if (content is String) {
    tokens += estimateTextTokens(content);
  } else if (content is List) {
    for (final part in content) {
      if (part is Map) {
        final text = part['text'];
        if (text is String) tokens += estimateTextTokens(text);
        if (part['image_url'] != null) tokens += 1500; // Typical vision tile tokens
        if (part['input_audio'] != null) tokens += 1000;
        if (part['video_url'] != null) tokens += 2000;
      } else {
        tokens += 20;
      }
    }
  }

  final reasoning = message['reasoning'] ?? message['reasoning_content'];
  if (reasoning is String) {
    tokens += estimateTextTokens(reasoning);
  }
  final reasoningDetails = message['reasoning_details'];
  if (reasoningDetails is List && reasoningDetails.isNotEmpty) {
    tokens += estimateTextTokens(jsonEncode(reasoningDetails));
  }

  final toolCalls = message['tool_calls'];
  if (toolCalls is List) {
    for (final call in toolCalls) {
      if (call is Map) {
        final fn = call['function'];
        if (fn is Map) {
          tokens += estimateTextTokens(fn['name']?.toString() ?? '');
          tokens += estimateTextTokens(fn['arguments']?.toString() ?? '');
        }
      }
    }
  }

  return tokens;
}

/// Estimates total tokens for a list of low-level LLM messages.
int estimateLlmMessagesTokens(List<Map<String, dynamic>> messages) =>
    messages.fold(0, (sum, m) => sum + estimateLlmMessageTokens(m));

// ---- Compaction Building Blocks --------------------------------------------

/// Prepares the prompt sent to the LLM to compact older conversation history.
List<Map<String, dynamic>> buildCompactionPrompt(
  List<Map<String, dynamic>> messagesToCompact,
) {
  final formatted = StringBuffer();
  for (final msg in messagesToCompact) {
    final role = msg['role'];
    final content = msg['content'];
    final toolCalls = msg['tool_calls'];
    final reasoning = msg['reasoning'] ?? msg['reasoning_content'];

    if (role == 'system') continue;

    if (reasoning is String && reasoning.isNotEmpty) {
      final snippet = reasoning.length > 1000
          ? '${reasoning.substring(0, 1000)}... [truncated]'
          : reasoning;
      formatted.writeln('[Model Thinking]: $snippet\n');
    }

    if (role == 'user') {
      if (content is String) {
        formatted.writeln('[User]: $content\n');
      } else if (content is List) {
        formatted.writeln('[User attached media/content]\n');
      }
    } else if (role == 'assistant') {
      if (content is String && content.isNotEmpty) {
        formatted.writeln('[Assistant]: $content\n');
      }
      if (toolCalls is List) {
        for (final call in toolCalls) {
          if (call is Map && call['function'] is Map) {
            formatted.writeln(
              '[Assistant called tool]: ${call['function']['name']}(${call['function']['arguments']})\n',
            );
          }
        }
      }
    } else if (role == 'tool') {
      final text = content is String ? content : '';
      final snippet = text.length > 2000
          ? '${text.substring(0, 2000)}... [truncated]'
          : text;
      formatted.writeln('[Tool result]: $snippet\n');
    }
  }

  return [
    const {
      'role': 'system',
      'content':
          'You are a context compactor for an autonomous AI assistant.\n'
          'Summarize the preceding conversation and tool execution history into a clear, continuation-ready state briefing.\n\n'
          'Core Principles:\n'
          '1. Focus on Core User Concern: Keep the user\'s primary objective, explicit preferences, and constraints front and center.\n'
          '2. Bias to Recency: Heavily compress older exploratory steps, superseded screens, and trial-and-error into brief 1-line outcomes. Retain higher detail for recent findings, active files, current screen/app state, and latest results.\n'
          '3. Dense & Factual: Preserve exact file paths, identifiers, URLs, and unfinished tasks. Do not preserve discarded chain-of-thought or raw repetitive tool logs.',
    },
    {
      'role': 'user',
      'content':
          'Compact the following history into a continuation-ready state briefing, prioritizing the user\'s core concern and recent state:\n\n'
          '${formatted.toString()}\n\n'
          'Use these sections:\n'
          '## 1. Primary User Goal\n'
          'What the user wants to accomplish and active constraints.\n\n'
          '## 2. Recent State & Key Findings\n'
          'Current state, recent discoveries, active files, and relevant results (summarize older intermediate steps very briefly).\n\n'
          '## 3. Unresolved Issues & Next Steps\n'
          'What remains to be done and what the agent should tackle next.\n\n'
          'Be concise, factual, and dense with actionable information.',
    },
  ];
}

/// Builds a deterministic fallback summary when the compaction LLM call fails or times out.
String buildDeterministicFallbackSummary(
  List<Map<String, dynamic>> messagesToCompact,
) {
  final buffer = StringBuffer();
  buffer.writeln('## 1. Primary User Goal');

  String? firstUserGoal;
  final toolsUsed = <String>[];
  final filesReferenced = <String>{};
  final errorSnippets = <String>[];

  for (final msg in messagesToCompact) {
    final role = msg['role'];
    final content = msg['content'];

    if (role == 'user' && content is String && firstUserGoal == null) {
      if (!content.startsWith('[Media file')) {
        if (content.contains('## 1. Primary User Goal')) {
          final lines = content.split('\n');
          final idx = lines.indexWhere((l) => l.trim() == '## 1. Primary User Goal');
          if (idx != -1 && idx + 1 < lines.length) {
            final goalLine = lines.sublist(idx + 1).firstWhere(
              (l) => l.trim().isNotEmpty && !l.startsWith('##'),
              orElse: () => '',
            );
            if (goalLine.isNotEmpty) {
              firstUserGoal = goalLine.trim();
            }
          }
        } else if (!content.startsWith(kCompactedContextMarker) &&
            !content.startsWith('[Compacted Conversation History')) {
          firstUserGoal = content.trim();
        }
      }
    }

    final toolCalls = msg['tool_calls'];
    if (toolCalls is List) {
      for (final call in toolCalls) {
        if (call is Map && call['function'] is Map) {
          final fnName = call['function']['name']?.toString() ?? 'tool';
          final argsStr = call['function']['arguments']?.toString() ?? '{}';
          toolsUsed.add('$fnName($argsStr)');
          try {
            final args = jsonDecode(argsStr);
            if (args is Map) {
              final pathVal = args['path'] ?? args['file'] ?? args['target'];
              if (pathVal is String) filesReferenced.add(pathVal);
            }
          } catch (_) {}
        }
      }
    }

    if (role == 'tool' && content is String) {
      if (content.toLowerCase().contains('error') || content.toLowerCase().contains('failed')) {
        final line = content.split('\n').first.trim();
        if (line.isNotEmpty && errorSnippets.length < 5) {
          errorSnippets.add(line);
        }
      }
    }
  }

  buffer.writeln(firstUserGoal ?? 'Continue user request and ongoing task.');
  buffer.writeln('\n## 2. Completed Actions & Findings');
  if (filesReferenced.isNotEmpty) {
    buffer.writeln('Files referenced: ${filesReferenced.join(', ')}');
  }
  if (toolsUsed.isNotEmpty) {
    final recentTools = toolsUsed.length > 8 ? toolsUsed.sublist(toolsUsed.length - 8) : toolsUsed;
    buffer.writeln('Recent tool invocations: ${recentTools.join('; ')}');
  }
  if (errorSnippets.isNotEmpty) {
    buffer.writeln('Recent error notes: ${errorSnippets.join('; ')}');
  }

  buffer.writeln('\n## 3. Current Progress & Immediate Next Steps');
  buffer.writeln('Context was compacted due to token threshold. Resume execution with current step.');
  return buffer.toString();
}

/// Applies a compacted summary into the message history, retaining system message and tail.
List<Map<String, dynamic>> applyCompactedHistory({
  required Map<String, dynamic> systemMessage,
  required String summary,
  required List<Map<String, dynamic>> tailMessages,
}) {
  final compactedHeader = {
    'role': 'user',
    'content': '$kCompactedContextMarker\n$summary',
  };

  if (tailMessages.isEmpty) {
    return [
      systemMessage,
      compactedHeader,
      const {
        'role': 'assistant',
        'content':
            'I have incorporated the compacted conversation history and previous tool execution state. '
            'Continuing with the task.',
      },
    ];
  }

  if (tailMessages.first['role'] == 'assistant') {
    return [
      systemMessage,
      compactedHeader,
      ...tailMessages,
    ];
  }

  return [
    systemMessage,
    compactedHeader,
    const {
      'role': 'assistant',
      'content':
          'I have incorporated the compacted conversation history and previous tool execution state. '
          'Continuing with the task.',
    },
    ...tailMessages,
  ];
}

// ---- Tail fitting ----------------------------------------------------------
//
// keepCount in the compactor floors at 1 tail block so the active turn is
// never dropped — but one block of multi-KB tool results (screen outlines,
// reads) can still exceed small-window targets on its own. Trimming whole
// blocks further is not an option; instead this pass head-trims oversized
// tool-result CONTENTS inside the tail, keeping block structure (ids, call
// mapping) intact so the next turn still references valid tool results.

/// Floor (in chars) for intra-tail tool-result trimming.
const int kTailTrimFloorChars = 1000;

const String _tailTrimMarker = '\n[...trimmed for compaction ';

/// Shrinks an oversized [tail] to fit [budget.targetTokens] without dropping
/// blocks. Oldest tool results are trimmed first; the newest tool message is
/// trimmed last since it carries the freshest results. Non-string contents
/// (media payloads) and non-tool messages are never touched. Best-effort:
/// returns the tail unchanged when nothing trimmable remains.
List<Map<String, dynamic>> fitTailToTarget(
  List<Map<String, dynamic>> tail,
  ContextBudget budget,
) {
  if (estimateLlmMessagesTokens(tail) <= budget.targetTokens) return tail;
  final fitted = [
    for (final m in tail) Map<String, dynamic>.from(m),
  ];
  String? trimAt(int i) {
    if (fitted[i]['role'] != 'tool') return null;
    final content = fitted[i]['content'];
    if (content is! String) return null;
    if (content.length <= kTailTrimFloorChars) return null;
    if (content.contains(_tailTrimMarker)) return null; // already trimmed
    return content;
  }

  while (estimateLlmMessagesTokens(fitted) > budget.targetTokens) {
    var newestTool = -1;
    for (var i = fitted.length - 1; i >= 0; i--) {
      if (trimAt(i) != null) {
        newestTool = i;
        break;
      }
    }
    if (newestTool == -1) break; // nothing left worth trimming
    var target = -1;
    for (var i = 0; i < newestTool; i++) {
      if (trimAt(i) != null) {
        target = i;
        break;
      }
    }
    target = target == -1 ? newestTool : target; // newest only as last resort
    final content = trimAt(target)!;
    final dropped = content.length - kTailTrimFloorChars;
    fitted[target]['content'] =
        '${content.substring(0, kTailTrimFloorChars)}$_tailTrimMarker$dropped chars]';
  }
  return fitted;
}

// ---- Legacy & Character Compatibility Layer --------------------------------

/// Estimates characters for a [Message].
int estimateMessageChars(Message message) {
  var size = message.text.length + _perMessageOverheadChars;
  if (message is UserMessage && message.attachedUris.isNotEmpty) {
    size += jsonEncode(message.attachedUris).length;
  }
  if (message is ToolMessage) {
    size += message.tool.name.length;
    size += jsonEncode(message.tool.args).length;
    size += message.result.length;
    size += message.reasoning?.length ?? 0;
    if (message.reasoningDetails.isNotEmpty) {
      size += jsonEncode(message.reasoningDetails).length;
    }
  }
  if (message is ErrorMessage) {
    size += message.error.length;
  }
  if (message is CompactedNoticeMessage && message.summary.isNotEmpty) {
    size += message.summary.length;
  }
  return size;
}

int estimateHistoryChars(List<Message> history) =>
    history.fold(0, (sum, message) => sum + estimateMessageChars(message));

List<Message> clampToolResults(List<Message> history) => [
  for (final message in history) _clampToolResult(message),
];

Message _clampToolResult(Message message) {
  if (message is! ToolMessage) return message;
  if (message.result.length <= kMaxToolResultChars) return message;
  final dropped = message.result.length - kMaxToolResultChars;
  return ToolMessage(
    id: message.id,
    text: message.text,
    tool: message.tool,
    result:
        '${message.result.substring(0, kMaxToolResultChars)}'
        '$_truncationMarker$dropped chars]',
    reasoning: message.reasoning,
    reasoningDetails: message.reasoningDetails,
  );
}

List<List<Message>> groupIntoUnits(List<Message> history) {
  final units = <List<Message>>[];
  var index = 0;
  while (index < history.length) {
    final message = history[index];
    if (message is ToolMessage) {
      final run = <Message>[message];
      while (index + 1 < history.length && history[index + 1] is ToolMessage) {
        index++;
        run.add(history[index]);
      }
      units.add(run);
    } else {
      units.add([message]);
    }
    index++;
  }
  return units;
}

/// Groups high-level [Message] history into atomic blocks corresponding to turns/tool batches.
List<List<Message>> groupHistoryIntoBlocks(List<Message> history) {
  final blocks = <List<Message>>[];
  var i = 0;
  while (i < history.length) {
    final msg = history[i];
    if (msg is AssistantMessage && i + 1 < history.length && history[i + 1] is ToolMessage) {
      final block = <Message>[msg];
      var j = i + 1;
      while (j < history.length && history[j] is ToolMessage) {
        block.add(history[j]);
        j++;
      }
      blocks.add(block);
      i = j;
    } else if (msg is ToolMessage) {
      final block = <Message>[msg];
      var j = i + 1;
      while (j < history.length && history[j] is ToolMessage) {
        block.add(history[j]);
        j++;
      }
      blocks.add(block);
      i = j;
    } else {
      blocks.add([msg]);
      i++;
    }
  }
  return blocks;
}

/// Truncates conversation history for payload boundaries.
List<Message> truncateHistory(
  List<Message> history, {
  int softLimit = kContextSoftLimit,
  int targetLimit = kContextTarget,
}) {
  if (history.isEmpty) return history;

  final clamped = clampToolResults(history);
  if (estimateHistoryChars(clamped) <= softLimit) return clamped;

  final units = groupIntoUnits(clamped);

  var lastUserUnit = -1;
  for (var i = 0; i < units.length; i++) {
    if (units[i].first is UserMessage) lastUserUnit = i;
  }

  final keptUnits = <List<Message>>[];
  var budget = 0;
  for (var i = units.length - 1; i >= 0; i--) {
    final unitSize = estimateHistoryChars(units[i]);
    final isMandatory = i >= lastUserUnit && lastUserUnit != -1;
    if (!isMandatory && budget + unitSize > targetLimit) break;
    budget += unitSize;
    keptUnits.add(units[i]);
  }

  if (keptUnits.isEmpty) keptUnits.add(units.last);

  return [
    for (final unit in keptUnits.reversed) ...unit,
  ];
}

String clampResultText(String text) {
  if (text.length <= kMaxToolResultChars) return text;
  final dropped = text.length - kMaxToolResultChars;
  return '${text.substring(0, kMaxToolResultChars)}'
      '$_truncationMarker$dropped chars]';
}

int _llmMessageChars(Map<String, dynamic> message) {
  var size = _perMessageOverheadChars;
  final content = message['content'];
  if (content is String) {
    size += content.length;
  } else if (content is List) {
    for (final part in content) {
      if (part is Map) {
        final text = part['text'];
        if (text is String) size += text.length + 20;
        final img = part['image_url'];
        if (img is Map && img['url'] is String) size += (img['url'] as String).length + 30;
        final audio = part['input_audio'];
        if (audio is Map && audio['data'] is String) size += (audio['data'] as String).length + 30;
        final video = part['video_url'];
        if (video is Map && video['url'] is String) size += (video['url'] as String).length + 30;
      } else {
        size += 100;
      }
    }
  }
  final toolCalls = message['tool_calls'];
  if (toolCalls is List) {
    for (final call in toolCalls) {
      if (call is Map) {
        final fn = call['function'];
        if (fn is Map) {
          size += (fn['name']?.toString().length ?? 0);
          size += (fn['arguments']?.toString().length ?? 0);
        }
      }
    }
  }
  return size;
}

bool isSyntheticMediaMessage(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is List && content.isNotEmpty) {
    final first = content.first;
    if (first is Map && first['text'] is String) {
      final text = first['text'] as String;
      if (text.startsWith('[Media file(s) you just read')) return true;
    }
  }
  return false;
}

int estimateLlmMessagesChars(List<Map<String, dynamic>> messages) =>
    messages.fold(0, (sum, m) => sum + _llmMessageChars(m));

List<Map<String, dynamic>> trimLlmMessages(
  List<Map<String, dynamic>> messages, {
  int softLimit = kContextSoftLimit,
  int targetLimit = kContextTarget,
}) {
  if (estimateLlmMessagesChars(messages) <= softLimit) return messages;

  var start = 0;
  if (messages.isNotEmpty && messages.first['role'] == 'system') start = 1;

  final blocks = <(int, int)>[];
  var i = start;
  while (i < messages.length) {
    final toolCalls = messages[i]['tool_calls'];
    if (messages[i]['role'] == 'assistant' && toolCalls is List && toolCalls.isNotEmpty) {
      var j = i + 1;
      while (j < messages.length && messages[j]['role'] == 'tool') {
        j++;
      }
      blocks.add((i, j));
      i = j;
    } else {
      blocks.add((i, i + 1));
      i++;
    }
  }
  if (blocks.isEmpty) return messages;

  var lastUserBlock = -1;
  for (var b = 0; b < blocks.length; b++) {
    for (var m = blocks[b].$1; m < blocks[b].$2; m++) {
      final msg = messages[m];
      if (msg['role'] == 'user' && !isSyntheticMediaMessage(msg)) {
        lastUserBlock = b;
      }
    }
  }
  if (lastUserBlock == -1) {
    for (var b = 0; b < blocks.length; b++) {
      for (var m = blocks[b].$1; m < blocks[b].$2; m++) {
        if (messages[m]['role'] == 'user') lastUserBlock = b;
      }
    }
  }

  var total = estimateLlmMessagesChars(messages.sublist(start));
  var dropped = false;
  for (var b = 0; b < blocks.length && total > targetLimit; b++) {
    if (b == lastUserBlock) continue;
    final (from, to) = blocks[b];
    for (var m = from; m < to; m++) {
      total -= _llmMessageChars(messages[m]);
    }
    dropped = true;
    blocks[b] = (-1, -1);
  }
  if (!dropped) return messages;

  return [
    for (var m = 0; m < start; m++) messages[m],
    for (final (from, to) in blocks)
      if (from != -1)
        for (var m = from; m < to; m++) messages[m],
  ];
}
