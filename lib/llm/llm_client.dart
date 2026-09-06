import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../agent/tool.dart';

/// Shared cancellation flag for an in-flight agent turn. The UI sets it
/// from the stop button; the client checks it between SSE events and the
/// loop checks it at turn boundaries.
///
/// Cancellation is ABORTIVE, not just cooperative: HTTP clients backing
/// in-flight requests are registered here and [cancel] closes them, which
/// kills the underlying sockets immediately. This is what makes stop work
/// during the time-to-first-token window, where no code of ours runs to
/// poll the flag.
class CancelToken {
  bool _cancelled = false;
  final Set<http.Client> _clients = {};

  bool get isCancelled => _cancelled;

  /// Registers the client backing one or more in-flight requests.
  void register(http.Client client) => _clients.add(client);

  /// Removes a client whose request finished on its own, so a later
  /// [cancel] cannot close it out from under unrelated work.
  void unregister(http.Client client) => _clients.remove(client);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // Closing makes every pending send/stream fail immediately with a
    // ClientException instead of waiting for server bytes or timeout.
    for (final client in {..._clients}) {
      client.close();
    }
    _clients.clear();
  }

  void reset() => _cancelled = false;
}

/// Thrown at the next safe boundary after [CancelToken.cancel]. In-flight
/// native tool calls cannot be interrupted — text streamed so far stays on
/// screen and becomes the final answer.
class LlmStoppedException implements Exception {
  const LlmStoppedException();

  @override
  String toString() => 'Stopped';
}

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

  Map<String, dynamic> toJson({bool includeReasoning = false}) => {
    'role': 'assistant',
    if (content != null && content!.isNotEmpty) 'content': content,
    if (includeReasoning && reasoning != null && reasoning!.isNotEmpty)
      'reasoning': reasoning,
    if (includeReasoning && reasoningDetails.isNotEmpty)
      'reasoning_details': reasoningDetails,
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
  final http.Client? _injectedClient;

  /// True when [LlmClient] created client connections itself (production).
  /// In that case each request gets a short-lived client so [CancelToken.cancel]
  /// can close it and abort in-flight work. An injected client (tests,
  /// shared usage) is reused as-is instead.
  final bool _ownsClient;

  LlmClient({required this.config, http.Client? client})
    : _injectedClient = client,
      _ownsClient = client == null;

  /// Client for one call/attempt: fresh + abortable when we own the
  /// lifecycle, otherwise the injected instance.
  http.Client _clientForCall() =>
      _injectedClient ?? http.Client();

  static const _timeout = Duration(seconds: 30);
  static const _streamTimeout = Duration(seconds: 60);
  static const _maxAttempts = 3;

  Uri _chatCompletionsUri() {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
    final body = _buildBody(messages: messages, tools: tools);

    final res = await _postWithRetry(
      _chatCompletionsUri(),
      {
        HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.authorizationHeader: 'Bearer ${config.apiKey}',
      },
      jsonEncode(body),
      cancelToken,
    );

    if (res.statusCode != 200) {
      throw LlmException(
        cleanErrorMessage(res.statusCode, res.body),
        transport: res.statusCode == 429 || res.statusCode >= 500,
      );
    }

    final dynamic rawData = jsonDecode(res.body);
    if (rawData is! Map<String, dynamic>) {
      throw LlmException('Invalid response: expected JSON object');
    }
    final choices = rawData['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('No choices returned in response');
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      throw LlmException('Invalid choice: expected JSON object');
    }
    final message = firstChoice['message'];
    if (message is! Map<String, dynamic>) {
      throw LlmException('Invalid message: expected JSON object');
    }

    final toolCalls = _parseToolCalls(
      message['tool_calls'] as List<dynamic>? ?? const [],
    );

    final text = message['content'] as String?;
    if ((text == null || text.trim().isEmpty) && toolCalls.isEmpty) {
      throw LlmException('Model returned an empty response', transport: true);
    }

    return LlmMessage(
      content: text,
      toolCalls: toolCalls,
      reasoning: _readReasoning(message),
      reasoningDetails: _parseReasoningDetails(message['reasoning_details']),
    );
  }

  /// POST with retry for transient failures: connection aborts (stale
  /// keep-alive sockets, mobile network switches), timeouts, HTTP 429/5xx.
  /// Honors `Retry-After` when present. Cancellation aborts the in-flight
  /// request by closing its client and is never retried.
  Future<http.Response> _postWithRetry(
    Uri uri,
    Map<String, String> headers,
    String body,
    CancelToken? cancelToken,
  ) async {
    for (var attempt = 1;; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmStoppedException();
      }
      final client = _clientForCall();
      cancelToken?.register(client);
      try {
        final res = await client
            .post(uri, headers: headers, body: body)
            .timeout(_timeout);
        final transient = res.statusCode == 429 || res.statusCode >= 500;
        if (!transient || attempt >= _maxAttempts) return res;
        await _backoff(attempt, res.headers['retry-after'], cancelToken);
      } on LlmStoppedException {
        rethrow;
      } on TimeoutException {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) {
          throw LlmException(
            'Request timed out after ${_timeout.inSeconds}s',
            transport: true,
          );
        }
        await _backoff(attempt, null, cancelToken);
      } on SocketException catch (e) {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) {
          throw LlmException('Connection lost: ${e.message}', transport: true);
        }
        await _backoff(attempt, null, cancelToken);
      } on HttpException catch (e) {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) {
          throw LlmException('Connection lost: ${e.message}', transport: true);
        }
        await _backoff(attempt, null, cancelToken);
      } on http.ClientException catch (e) {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) {
          throw LlmException('Connection lost: ${e.message}', transport: true);
        }
        await _backoff(attempt, null, cancelToken);
      } finally {
        cancelToken?.unregister(client);
        if (_ownsClient) client.close();
      }
    }
  }

  /// A cancelled request surfaces as ClientException ("client closed") /
  /// SocketException from the aborted socket — map it to the stop signal
  /// instead of treating it as a transport failure (or worse: retrying it).
  void _rethrowIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
  }

  Future<void> _backoff(
    int attempt,
    String? retryAfter,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
    final seconds = int.tryParse(retryAfter ?? '');
    final delay = seconds != null && seconds > 0
        ? Duration(seconds: seconds)
        : Duration(milliseconds: 800 * (1 << (attempt - 1)));
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < delay) {
      if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
      final remaining = delay - stopwatch.elapsed;
      final step = remaining < const Duration(milliseconds: 100)
          ? remaining
          : const Duration(milliseconds: 100);
      await Future<void>.delayed(step);
    }
    if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
  }

  /// Stream send with retry — covers the phase until response headers
  /// arrive (transient 429/5xx, timeouts, socket drops); mid-stream failures
  /// cannot be transparently resumed.
  /// [buildRequest] is invoked per attempt because an [http.Request] can only
  /// be finalized once. All attempts share [client] so a cancel closes the
  /// in-flight attempt instantly.
  Future<http.StreamedResponse> _sendStreamWithRetry(
    http.Client client,
    http.Request Function() buildRequest,
    CancelToken? cancelToken,
  ) async {
    for (var attempt = 1;; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmStoppedException();
      }
      try {
        final response =
            await client.send(buildRequest()).timeout(_streamTimeout);
        final transient =
            response.statusCode == 429 || response.statusCode >= 500;
        if (!transient || attempt >= _maxAttempts) {
          return response;
        }
        await response.stream.drain<void>().catchError((_) {});
        await _backoff(attempt, response.headers['retry-after'], cancelToken);
      } on LlmStoppedException {
        rethrow;
      } on TimeoutException {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null, cancelToken);
      } on SocketException {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null, cancelToken);
      } on HttpException {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null, cancelToken);
      } on http.ClientException {
        _rethrowIfCancelled(cancelToken);
        if (attempt >= _maxAttempts) rethrow;
        await _backoff(attempt, null, cancelToken);
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
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
    final streamBody = jsonEncode({
      ..._buildBody(messages: messages, tools: tools),
      'stream': true,
    });

    // One client backs the whole call (send + stream reads), registered so
    // a cancel aborts it at ANY phase: time-to-first-token, header waits,
    // and mid-stream. An injected client (tests) is reused as-is.
    final client = _clientForCall();
    cancelToken?.register(client);
    try {
      http.StreamedResponse response;
      try {
        // A fresh http.Request must be built per attempt — package:http
        // finalizes a Request on first send and re-sending throws
        // "Bad state: Can't finalize a finalized Request".
        response = await _sendStreamWithRetry(client, () {
          return http.Request(
            'POST',
            _chatCompletionsUri(),
          )
            ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
            ..headers[HttpHeaders.authorizationHeader] =
                'Bearer ${config.apiKey}'
            ..headers[HttpHeaders.acceptHeader] = 'text/event-stream'
            ..body = streamBody;
        }, cancelToken);
      } on LlmStoppedException {
        rethrow;
      } on TimeoutException {
        throw LlmException(
          'Request timed out after ${_streamTimeout.inSeconds}s',
          transport: true,
        );
      } on SocketException catch (e) {
        _rethrowIfCancelled(cancelToken);
        throw LlmException('Connection lost: ${e.message}', transport: true);
      } on HttpException catch (e) {
        _rethrowIfCancelled(cancelToken);
        throw LlmException('Connection lost: ${e.message}', transport: true);
      } on http.ClientException catch (e) {
        _rethrowIfCancelled(cancelToken);
        throw LlmException('Connection lost: ${e.message}', transport: true);
      }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(
        cleanErrorMessage(response.statusCode, body),
        transport: response.statusCode == 429 || response.statusCode >= 500,
      );
    }

    final contentType = response.headers[HttpHeaders.contentTypeHeader] ??
        response.headers['content-type'] ??
        '';

    if (!contentType.contains('text/event-stream') &&
        (contentType.contains('application/json') ||
            contentType.contains('text/json'))) {
      final body = await response.stream.bytesToString();
      final dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException catch (e) {
        throw LlmException('Malformed response: $e', transport: true);
      }

      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          throw LlmException(error['message'].toString());
        } else if (error is String && error.isNotEmpty) {
          throw LlmException(error);
        } else if (decoded['detail'] != null) {
          throw LlmException(decoded['detail'].toString());
        }

        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final firstChoice = choices.first;
          if (firstChoice is Map<String, dynamic>) {
            final message = firstChoice['message'];
            if (message is Map<String, dynamic>) {
              final text = message['content'] as String?;
              if (text != null && text.isNotEmpty) {
                onTextDelta(text);
              }
              final reasoningText = _readReasoning(message);
              if (reasoningText != null && reasoningText.isNotEmpty) {
                onReasoningDelta?.call();
              }
              final toolCalls = _parseToolCalls(
                message['tool_calls'] as List<dynamic>? ?? const [],
              );
              if ((text == null || text.isEmpty) && toolCalls.isEmpty) {
                throw LlmException('Model returned an empty response', transport: true);
              }
              return LlmMessage(
                content: (text == null || text.isEmpty) ? null : text,
                reasoning: reasoningText,
                reasoningDetails: _parseReasoningDetails(message['reasoning_details']),
                toolCalls: toolCalls,
              );
            }
          }
        }
      }
      throw LlmException('Unexpected non-streaming response: $body', transport: true);
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final reasoningDetails = <Map<String, dynamic>>[];
    final streamedToolCalls = <int, _StreamToolCall>{};
    var lastToolCallIndex = 0;

    try {
      await for (final event in _sseDataEvents(response.stream)) {
        if (cancelToken?.isCancelled ?? false) {
          throw const LlmStoppedException();
        }
        if (event == '[DONE]') break;

        final Map<String, dynamic> data;
        try {
          final decoded = jsonDecode(event);
          if (decoded is! Map<String, dynamic>) continue;
          data = decoded;
        } on FormatException catch (e) {
          throw LlmException('Malformed streaming event: $e', transport: true);
        }

        final error = data['error'];
        if (error is String && error.isNotEmpty) {
          throw LlmException(error);
        } else if (error is Map<String, dynamic>) {
          throw LlmException(error['message']?.toString() ?? 'Streaming error');
        }

        final detail = data['detail'];
        if (detail is String && detail.isNotEmpty) {
          throw LlmException(detail);
        }

        final messageField = data['message'];
        if (messageField is String && messageField.isNotEmpty && data['choices'] == null) {
          throw LlmException(messageField);
        }

        final choices = data['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;

        final choiceError = choice['error'];
        if (choiceError is Map<String, dynamic>) {
          throw LlmException(choiceError['message']?.toString() ?? 'Streaming error');
        } else if (choiceError is String && choiceError.isNotEmpty) {
          throw LlmException(choiceError);
        }

        final finishReason = choice['finish_reason'] as String?;
        if (finishReason == 'error') {
          throw LlmException('Model generation failed upstream (finish_reason: error)');
        }
        if (finishReason == 'content_filter') {
          throw LlmException('Generation stopped by content filter');
        }

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
          if (raw is! Map<String, dynamic>) continue;
          final toolCall = raw;
          final parsedIndex = (toolCall['index'] as num?)?.toInt();
          final index = parsedIndex ??
              (streamedToolCalls.isNotEmpty
                  ? lastToolCallIndex
                  : streamedToolCalls.length);
          lastToolCallIndex = index;
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
    } on LlmStoppedException {
      rethrow;
    } on SocketException catch (e) {
      _rethrowIfCancelled(cancelToken);
      throw LlmException('Stream interrupted: ${e.message}', transport: true);
    } on HttpException catch (e) {
      _rethrowIfCancelled(cancelToken);
      throw LlmException('Stream interrupted: ${e.message}', transport: true);
    } on http.ClientException catch (e) {
      _rethrowIfCancelled(cancelToken);
      throw LlmException('Stream interrupted: ${e.message}', transport: true);
    }

    final toolCalls = <ToolCall>[];
    for (final entry in streamedToolCalls.entries) {
      final call = entry.value.tryToToolCall(index: entry.key);
      if (call != null) toolCalls.add(call);
    }

    if (content.isEmpty && toolCalls.isEmpty) {
      throw LlmException('Model returned an empty response', transport: true);
    }

    return LlmMessage(
      content: content.isEmpty ? null : content.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      reasoningDetails: reasoningDetails,
      toolCalls: toolCalls,
    );
    } finally {
      cancelToken?.unregister(client);
      // Safe in all exit paths: normal completion, mid-stream stop, or an
      // exception propagating — the socket is either done or being aborted.
      // Injected clients are owned elsewhere; leave them open.
      if (_ownsClient) client.close();
    }
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
    final id = call['id'] as String? ?? '';
    final fn = call['function'] as Map<String, dynamic>? ?? const {};
    final name = fn['name'] as String? ?? '';
    final rawArgs = fn['arguments'];
    Map<String, dynamic> arguments;
    if (rawArgs is Map<String, dynamic>) {
      arguments = rawArgs;
    } else if (rawArgs is Map) {
      arguments = Map<String, dynamic>.from(rawArgs);
    } else {
      try {
        final parsed = jsonDecode(
          rawArgs is String && rawArgs.trim().isNotEmpty ? rawArgs : '{}',
        );
        if (parsed is Map<String, dynamic>) {
          arguments = parsed;
        } else if (parsed is Map) {
          arguments = Map<String, dynamic>.from(parsed);
        } else {
          throw LlmException('Tool arguments must be a JSON object');
        }
      } on FormatException catch (e) {
        throw LlmException('Malformed tool arguments: $e');
      }
    }
    return ToolCall(
      id: id,
      name: name,
      arguments: arguments,
    );
  }

  void close() => _injectedClient?.close();
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
      if (data.isNotEmpty) {
        yield data.toString();
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    if (!line.startsWith('data:')) continue;

    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    if (data.isNotEmpty) data.write('\n');
    data.write(value);
  }

  // Server may omit the final blank line before closing the stream.
  // Treat any buffered data as one last event (covers `data: [DONE]` without `\n\n`).
  if (data.isNotEmpty) yield data.toString();
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
    final rawArgs = arguments.toString().trim();
    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(rawArgs.isEmpty ? '{}' : rawArgs);
      if (parsed == null) {
        decoded = const {};
      } else if (parsed is Map<String, dynamic>) {
        decoded = parsed;
      } else if (parsed is Map) {
        decoded = Map<String, dynamic>.from(parsed);
      } else {
        throw LlmException('Tool arguments for $name must be a JSON object');
      }
    } on FormatException catch (e) {
      throw LlmException('Malformed tool arguments for $name: $e');
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

/// Formats HTTP status codes and response bodies (HTML error pages, raw JSON
/// dumps, or plain text) into concise, human-readable error messages.
String cleanErrorMessage(int statusCode, String rawBody) {
  final trimmed = rawBody.trim();
  if (trimmed.isEmpty) {
    return 'HTTP $statusCode: ${_httpStatusMessage(statusCode)}';
  }

  // 1. HTML error page (Cloudflare, Nginx, hosting proxies)
  if (trimmed.startsWith('<') ||
      trimmed.contains('<html') ||
      trimmed.contains('<!DOCTYPE')) {
    final titleMatch = RegExp(
      r'<title>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    if (titleMatch != null) {
      var title = titleMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      title = title.replaceFirst(
        RegExp('^$statusCode\\s*[:-]?\\s*', caseSensitive: false),
        '',
      );
      if (title.isNotEmpty) {
        return 'HTTP $statusCode: $title';
      }
    }
    final h1Match = RegExp(
      r'<h1>(.*?)</h1>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    if (h1Match != null) {
      var h1 = h1Match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      h1 = h1.replaceFirst(
        RegExp('^$statusCode\\s*[:-]?\\s*', caseSensitive: false),
        '',
      );
      if (h1.isNotEmpty) {
        return 'HTTP $statusCode: $h1';
      }
    }
    return 'HTTP $statusCode: ${_httpStatusMessage(statusCode)}';
  }

  // 2. JSON error responses
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final error = decoded['error'];
      String? msg;
      if (error is Map && error['message'] != null) {
        msg = error['message'].toString().trim();
      } else if (error is String && error.trim().isNotEmpty) {
        msg = error.trim();
      } else if (decoded['message'] != null) {
        msg = decoded['message'].toString().trim();
      } else if (decoded['detail'] != null) {
        msg = decoded['detail'].toString().trim();
      }
      if (msg != null && msg.isNotEmpty) {
        if (statusCode >= 400 &&
            !msg.startsWith('HTTP') &&
            !msg.startsWith('$statusCode')) {
          return 'HTTP $statusCode: $msg';
        }
        return msg;
      }
    }
  } catch (_) {
    // Not JSON
  }

  // 3. Short plain text responses
  final firstLine = trimmed.split('\n').first.trim();
  if (firstLine.isNotEmpty && firstLine.length <= 150) {
    if (firstLine.startsWith('HTTP') || firstLine.startsWith('$statusCode')) {
      return firstLine;
    }
    return 'HTTP $statusCode: $firstLine';
  }

  return 'HTTP $statusCode: ${_httpStatusMessage(statusCode)}';
}

String _httpStatusMessage(int statusCode) {
  switch (statusCode) {
    case 400:
      return 'Bad request';
    case 401:
      return 'Unauthorized: Invalid API key';
    case 403:
      return 'Access forbidden';
    case 404:
      return 'Endpoint or model not found';
    case 408:
      return 'Request timeout';
    case 429:
      return 'Rate limit exceeded';
    case 500:
      return 'Internal server error';
    case 502:
      return 'Bad Gateway: upstream service unavailable';
    case 503:
      return 'Service temporarily unavailable';
    case 504:
      return 'Gateway timeout';
    default:
      return statusCode >= 500 ? 'Server error' : 'Request failed';
  }
}

