import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../agent/tool.dart';

class LlmMessage {
  final String? content;
  final List<ToolCall> toolCalls;
  final String? reasoning;
  final List<Map<String, dynamic>> reasoningDetails;

  const LlmMessage({
    this.content,
    this.toolCalls = const [],
    this.reasoning,
    this.reasoningDetails = const [],
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'role': 'assistant',
    if (content != null && content!.isNotEmpty) 'content': content,
    if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    if (reasoningDetails.isNotEmpty) 'reasoning_details': reasoningDetails,
    if (hasToolCalls) 'tool_calls': toolCalls.map((t) => t.toJson()).toList(),
  };
}

class LlmConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });
}

class LlmClient {
  final LlmConfig config;
  final http.Client _client;

  LlmClient({required this.config, http.Client? client})
    : _client = client ?? http.Client();

  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
  }) async {
    final body = _buildBody(messages: messages, tools: tools);

    final res = await _client.post(
      Uri.parse('${config.baseUrl}/chat/completions'),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.authorizationHeader: 'Bearer ${config.apiKey}',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode != 200) {
      throw LlmException('HTTP ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final choice = (data['choices'] as List).first as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;

    final toolCalls = _parseToolCalls(
      message['tool_calls'] as List<dynamic>? ?? const [],
    );

    return LlmMessage(
      content: message['content'] as String?,
      toolCalls: toolCalls,
      reasoning: _readReasoning(message),
      reasoningDetails: _parseReasoningDetails(message['reasoning_details']),
    );
  }

  /// Sends an OpenAI-compatible streaming chat request.
  ///
  /// Text is forwarded as it arrives, while the returned [LlmMessage] still
  /// contains the complete response required by the agent loop. Tool-call
  /// arguments are accumulated until the stream is complete because they are
  /// delivered as partial JSON fragments.
  Future<LlmMessage> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    required void Function(String delta) onTextDelta,
    void Function()? onReasoningDelta,
  }) async {
    final request =
        http.Request('POST', Uri.parse('${config.baseUrl}/chat/completions'))
          ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer ${config.apiKey}'
          ..headers[HttpHeaders.acceptHeader] = 'text/event-stream'
          ..body = jsonEncode({
            ..._buildBody(messages: messages, tools: tools),
            'stream': true,
          });

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException('HTTP ${response.statusCode}: $body');
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final reasoningDetails = <Map<String, dynamic>>[];
    final streamedToolCalls = <int, _StreamToolCall>{};

    await for (final event in _sseDataEvents(response.stream)) {
      if (event == '[DONE]') break;

      final data = jsonDecode(event) as Map<String, dynamic>;
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        throw LlmException(error['message']?.toString() ?? 'Streaming error');
      }

      final choices = data['choices'] as List<dynamic>? ?? const [];
      if (choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>? ?? const {};

      final reasoningDelta = _readReasoning(delta);
      final reasoningDetailDelta = _parseReasoningDetails(
        delta['reasoning_details'],
      );
      if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
        reasoning.write(reasoningDelta);
      }
      if ((reasoningDelta != null && reasoningDelta.isNotEmpty) ||
          reasoningDetailDelta.isNotEmpty) {
        onReasoningDelta?.call();
      }
      _appendReasoningDetails(reasoningDetails, reasoningDetailDelta);

      final text = delta['content'];
      if (text is String && text.isNotEmpty) {
        content.write(text);
        onTextDelta(text);
      }

      final rawToolCalls = delta['tool_calls'] as List<dynamic>? ?? const [];
      for (final raw in rawToolCalls) {
        final toolCall = raw as Map<String, dynamic>;
        final index =
            (toolCall['index'] as num?)?.toInt() ?? streamedToolCalls.length;
        final accumulated = streamedToolCalls.putIfAbsent(
          index,
          _StreamToolCall.new,
        );
        accumulated.id ??= toolCall['id'] as String?;

        final function = toolCall['function'] as Map<String, dynamic>?;
        if (function == null) continue;
        accumulated.name ??= function['name'] as String?;
        final arguments = function['arguments'] as String?;
        if (arguments != null) accumulated.arguments.write(arguments);
      }
    }

    return LlmMessage(
      content: content.length == 0 ? null : content.toString(),
      reasoning: reasoning.length == 0 ? null : reasoning.toString(),
      reasoningDetails: reasoningDetails,
      toolCalls: [
        for (final entry in streamedToolCalls.entries)
          entry.value.toToolCall(index: entry.key),
      ],
    );
  }

  Map<String, dynamic> _buildBody({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
  }) => {
    'model': config.model,
    'messages': messages,
    'tools': tools.map((t) => t.toJson()).toList(),
    'tool_choice': 'auto',
  };

  String? _readReasoning(Map<String, dynamic> message) {
    final value = message['reasoning'] ?? message['reasoning_content'];
    return value is String ? value : null;
  }

  List<Map<String, dynamic>> _parseReasoningDetails(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final detail in raw)
        if (detail is Map) Map<String, dynamic>.from(detail),
    ];
  }

  void _appendReasoningDetails(
    List<Map<String, dynamic>> target,
    List<Map<String, dynamic>> incoming,
  ) {
    for (final detail in incoming) {
      final key = detail['id'] ?? detail['index'];
      final existingIndex = key == null
          ? -1
          : target.indexWhere(
              (current) =>
                  (current['id'] ?? current['index']) == key &&
                  current['type'] == detail['type'],
            );

      if (existingIndex == -1) {
        target.add(detail);
        continue;
      }

      final existing = target[existingIndex];
      for (final field in const ['text', 'summary', 'data']) {
        final next = detail[field];
        if (next is String && next.isNotEmpty) {
          final previous = existing[field];
          existing[field] = '${previous is String ? previous : ''}$next';
        }
      }
      for (final entry in detail.entries) {
        existing.putIfAbsent(entry.key, () => entry.value);
      }
    }
  }

  List<ToolCall> _parseToolCalls(List<dynamic> rawCalls) => [
    for (final raw in rawCalls) _parseToolCall(raw as Map<String, dynamic>),
  ];

  ToolCall _parseToolCall(Map<String, dynamic> call) {
    final fn = call['function'] as Map<String, dynamic>? ?? const {};
    final arguments = jsonDecode(fn['arguments'] as String? ?? '{}');
    if (arguments is! Map<String, dynamic>) {
      throw LlmException('Tool arguments must be a JSON object');
    }
    return ToolCall(
      id: call['id'] as String,
      name: fn['name'] as String,
      arguments: arguments,
    );
  }

  void close() => _client.close();
}

/// Extracts complete SSE data payloads from a streamed response.
///
/// The UTF-8 decoder is stateful, so multibyte characters split across HTTP
/// chunks are reconstructed correctly. Comment events are keepalives and are
/// intentionally ignored.
Stream<String> _sseDataEvents(Stream<List<int>> bytes) async* {
  final data = StringBuffer();
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());

  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.length > 0) {
        yield data.toString();
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    if (!line.startsWith('data:')) continue;

    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    if (data.length > 0) data.write('\n');
    data.write(value);
  }

  if (data.length > 0) yield data.toString();
}

class _StreamToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  ToolCall toToolCall({required int index}) {
    final decoded = jsonDecode(
      arguments.length == 0 ? '{}' : arguments.toString(),
    );
    if (decoded is! Map<String, dynamic>) {
      throw LlmException('Tool arguments must be a JSON object');
    }
    return ToolCall(
      id: id ?? 'tool-call-$index',
      name: name ?? '',
      arguments: decoded,
    );
  }
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);

  @override
  String toString() => message;
}
