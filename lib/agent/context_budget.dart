import 'dart:convert';

import '../types/message.dart';

/// Total assumed context window, in characters (~tokens x 4).
const int kContextWindowChars = 256 * 1024;

/// Truncation kicks in above this many estimated characters; below it the
/// history is sent untouched (apart from per-result clamping).
const int kContextSoftLimit = 200 * 1024;

/// After truncation the kept history should fit within this budget, leaving
/// headroom for the completion and tool schemas inside the 256K window.
const int kContextTarget = 110 * 1024;

/// A single tool result larger than this is head-clamped regardless of the
/// total budget, so one giant `read` cannot dominate the context.
const int kMaxToolResultChars = 32 * 1024;

/// Rough per-message JSON envelope overhead (role, ids, formatting).
const int _perMessageOverheadChars = 40;

const String _truncationMarker = '\n[...truncated ';

/// Estimates the characters a [Message] contributes to the LLM payload.
///
/// Mirrors what `_toLlmHistory` actually serializes: text plus, for tool
/// messages, the full result, reasoning, and JSON-encoded args/details.
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
  return size;
}

/// Estimates the total characters a history contributes to the LLM payload.
int estimateHistoryChars(List<Message> history) =>
    history.fold(0, (sum, message) => sum + estimateMessageChars(message));

/// Returns [history] with any oversized tool result head-clamped.
///
/// Applied unconditionally: even below the soft limit, a single multi-hundred-
/// kilobyte `read` output should not crowd out the rest of the conversation.
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

/// Groups a history into atomic truncation units.
///
/// Consecutive `ToolMessage`s form ONE unit: `_toLlmHistory` synthesizes a
/// single assistant `tool_calls` message from the whole run, so splitting a
/// run would produce an orphaned tool result or a dangling tool_calls block.
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

/// Sliding-window truncation over the conversation history.
///
/// - Under the soft limit: returns the history with tool results clamped only.
/// - Over the soft limit: drops whole oldest units (never mid-tool-batch)
///   until the kept suffix fits [targetLimit]. Everything from the most
///   recent [UserMessage] onwards is mandatory and always kept, even if that
///   alone exceeds the target.
///
/// Pure/non-destructive: the input list is never mutated and the full
/// history remains available for persistence and UI rendering.
List<Message> truncateHistory(
  List<Message> history, {
  int softLimit = kContextSoftLimit,
  int targetLimit = kContextTarget,
}) {
  if (history.isEmpty) return history;

  final clamped = clampToolResults(history);
  if (estimateHistoryChars(clamped) <= softLimit) return clamped;

  final units = groupIntoUnits(clamped);

  // Index of the unit containing the last user message; every unit from
  // there to the end is mandatory context for the current turn.
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
    // Collected back-to-front; flattened front-to-back below.
    keptUnits.add(units[i]);
  }

  // Degenerate case: no user message at all and the newest unit already
  // blows the target — still send something rather than nothing.
  if (keptUnits.isEmpty) keptUnits.add(units.last);

  return [
    for (final unit in keptUnits.reversed) ...unit,
  ];
}

// ---- Mid-loop payload management (P2b) --------------------------------------
//
// truncateHistory() runs once per run(), but an agentic turn APPENDS results
// as the loop progresses — a screen-automation flow adds ~12K per step. These
// helpers keep the in-loop LLM payload inside the same budget.

/// Head-clamps [text] to [kMaxToolResultChars], mirroring _clampToolResult.
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
    // Multimodal content parts: sum part payload lengths directly to avoid
    // running jsonEncode() on multi-megabyte base64 structures.
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
    // Arguments dominate; jsonEncode-length is close enough for a guard.
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

bool _isSyntheticMediaMessage(Map<String, dynamic> message) {
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

/// Sliding-window trim over the in-loop LLM payload (raw message maps).
///
/// Drops whole oldest blocks until the payload fits [targetLimit]. A block is
/// one of:
/// - an assistant `tool_calls` message PLUS its following `tool` results
///   (never split — orphaned tool results are API errors)
/// - any standalone assistant/user text message
///
/// Protection rules differ from [truncateHistory]: within a single agentic
/// run almost everything sits AFTER the one starting user message, so
/// "everything from the last user message is mandatory" would make this a
/// no-op. Instead only the system prompt and the last USER MESSAGE ITSELF
/// are protected; stale intermediate tool exchanges are fair game.
List<Map<String, dynamic>> trimLlmMessages(
  List<Map<String, dynamic>> messages, {
  int softLimit = kContextSoftLimit,
  int targetLimit = kContextTarget,
}) {
  if (estimateLlmMessagesChars(messages) <= softLimit) return messages;

  var start = 0;
  if (messages.isNotEmpty && messages.first['role'] == 'system') start = 1;

  // Partition into block ranges [from, to).
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

  // The last user-message block is mandatory (the run's instruction).
  // Exclude synthetic in-loop media delivery blocks so the user's real prompt
  // is protected.
  var lastUserBlock = -1;
  for (var b = 0; b < blocks.length; b++) {
    for (var m = blocks[b].$1; m < blocks[b].$2; m++) {
      final msg = messages[m];
      if (msg['role'] == 'user' && !_isSyntheticMediaMessage(msg)) {
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
  // Drop unprotected blocks oldest-first until under target. A protected
  // block (the last user message) is skipped, not a stopping condition.
  for (var b = 0; b < blocks.length && total > targetLimit; b++) {
    if (b == lastUserBlock) continue;
    final (from, to) = blocks[b];
    for (var m = from; m < to; m++) {
      total -= _llmMessageChars(messages[m]);
    }
    dropped = true;
    blocks[b] = (-1, -1); // mark dropped
  }
  if (!dropped) return messages;

  return [
    for (var m = 0; m < start; m++) messages[m],
    for (final (from, to) in blocks)
      if (from != -1)
        for (var m = from; m < to; m++) messages[m],
  ];
}
