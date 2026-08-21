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

  static const _timeout = Duration(seconds: 30);
  static const _streamTimeout = Duration(seconds: 60);
  static const _maxAttempts = 3;

  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
  }) async {
    final body = _buildBody(messages: messages, tools: tools);

    final res = await _postWithRetry(
      Uri.parse('${config.baseUrl}/chat/completions'),
      {
        HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.authorizationHeader: 'Bearer ${config.apiKey}',
      },
      jsonEncode(body),
    );

    if (res.statusCode != 200) {
      final truncated = res.body.length > 800 ? '${res.body.substring(0, 800)}…[truncated]' : res.body;
      throw LlmException(
        'HTTP ${res.statusCode}: $truncated',
        transport: res.statusCode == 429 || res.statusCode >= 500,
      );
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

  /// POST with retry for transient failures: connection aborts (stale
  /// keep-alive sockets, mobile network switches), timeouts, HTTP 429/5xx.
  /// Honors `Retry-After` when present.
  Future<http.Response> _postWithRetry(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    for (var attempt = 1;; attempt++) {
      try {
        final res = await _client
            .post(uri, headers: headers, body: body)
            .timeout(_timeout);
        final transient = res.statusCode == 429 || res.statusCode >= 500;
        if (!transient || attempt >= _maxAttempts) return res;
        await _backoff(attempt, res.headers['retry-after']);
      } on TimeoutException {
        if (attempt >= _maxAttempts) {
          throw LlmException(
            'Request timed out after ${_timeout.inSeconds}s',
            transport: true,
          );
        }
        await _backoff(attempt, null);
      } on SocketException catch (e) {
        if (attempt >= _maxAttempts) {
          throw LlmException('Connection lost: ${e.message}', transport: true);
        }
        await _backoff(attempt, null);
      } on http.ClientException catch (e) {
        if (attempt >= _maxAttempts) {
          throw LlmException('Connection lost: ${e.message}', transport: true);
        }
        await _backoff(attempt, null);
      }
    }
  }

  Future<void> _backoff(int attempt, String? retryAfter) async {
    final seconds = int.tryParse(retryAfter ?? '');
    final delay = seconds != null && seconds > 0
        ? Duration(seconds: seconds)
        : Duration(milliseconds: 800 * (1 << (attempt - 1)));
    await Future<void>.delayed(delay);
  }

  /// Stream send with retry — only covers the phase until response headers
  /// arrive; mid-stream failures cannot be transparently resumed.
  /// [buildRequest] is invoked per attempt because an [http.Request] can only
  /// be finalized once.
  Future<http.StreamedResponse> _sendStreamWithRetry(
    http.Request Function() buildRequest,
  ) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await _client.send(buildRequest()).timeout(_streamTimeout);
      } on TimeoutException {
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null);
      } on SocketException {
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null);
      } on http.ClientException {
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null);
      }
    }
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
    final streamBody = jsonEncode({
      ..._buildBody(messages: messages, tools: tools),
      'stream': true,
    });

    http.StreamedResponse response;
    try {
      // A fresh http.Request must be built per attempt — package:http
      // finalizes a Request on first send and re-sending throws
      // "Bad state: Can't finalize a finalized Request".
      response = await _sendStreamWithRetry(() {
        return http.Request(
          'POST',
          Uri.parse('${config.baseUrl}/chat/completions'),
        )
          ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer ${config.apiKey}'
          ..headers[HttpHeaders.acceptHeader] = 'text/event-stream'
          ..body = streamBody;
      });
    } on TimeoutException {
      throw LlmException(
        'Request timed out after ${_streamTimeout.inSeconds}s',
        transport: true,
      );
    } on SocketException catch (e) {
      throw LlmException('Connection lost: ${e.message}', transport: true);
    } on http.ClientException catch (e) {
      throw LlmException('Connection lost: ${e.message}', transport: true);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      final truncated = body.length > 800 ? '${body.substring(0, 800)}…[truncated]' : body;
      throw LlmException(
        'HTTP ${response.statusCode}: $truncated',
        transport: response.statusCode == 429 || response.statusCode >= 500,
      );
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final reasoningDetails = <Map<String, dynamic>>[];
    final streamedToolCalls = <int, _StreamToolCall>{};

    try {
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
    } on SocketException catch (e) {
      throw LlmException('Stream interrupted: ${e.message}', transport: true);
    } on http.ClientException catch (e) {
      throw LlmException('Stream interrupted: ${e.message}', transport: true);
    }

    final toolCalls = <ToolCall>[];
    for (final entry in streamedToolCalls.entries) {
      final call = entry.value.tryToToolCall(index: entry.key);
      if (call != null) toolCalls.add(call);
    }

    return LlmMessage(
      content: content.length == 0 ? null : content.toString(),
      reasoning: reasoning.length == 0 ? null : reasoning.toString(),
      reasoningDetails: reasoningDetails,
      toolCalls: toolCalls,
    );
  }

  Map<String, dynamic> _buildBody({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
  }) => {
    'model': config.model,
    'messages': messages,
    if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
    if (tools.isNotEmpty) 'tool_choice': 'auto',
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

  // Server may omit the final blank line before closing the stream.
  // Treat any buffered data as one last event (covers `data: [DONE]` without `\n\n`).
  if (data.length > 0) yield data.toString();
}

class _StreamToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  ToolCall? tryToToolCall({required int index}) {
    // Incomplete tool calls (missing id or name) happen when some proxies
    // stream partial deltas. Emitting a synthetic id like `tool-call-$index`
    // breaks the OpenAI contract: the subsequent `tool` message must carry
    // the exact `tool_call_id` the model issued, otherwise the next turn
    // is rejected as malformed history. Drop incomplete calls instead.
    if (id == null || id!.isEmpty) return null;
    if (name == null || name!.isEmpty) return null;
    final decoded = jsonDecode(
      arguments.length == 0 ? '{}' : arguments.toString(),
    );
    if (decoded is! Map<String, dynamic>) {
      throw LlmException('Tool arguments must be a JSON object');
    }
    return ToolCall(
      id: id!,
      name: name!,
      arguments: decoded,
    );
  }

  @Deprecated('Use tryToToolCall')
  ToolCall toToolCall({required int index}) {
    final call = tryToToolCall(index: index);
    if (call != null) return call;
    throw LlmException('Incomplete tool call at index $index');
  }
}

class LlmException implements Exception {
  final String message;

  /// True when the failure is transport/API-side (connection aborts,
  /// timeouts, HTTP 429/5xx) rather than an agent/tool mistake. Transport
  /// errors must be surfaced to the user but never added to model context.
  final bool transport;

  LlmException(this.message, {this.transport = false});

  @override
  String toString() => message;
}
