import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../agent/tool.dart';

class LlmMessage {
  final String? content;
  final List<ToolCall> toolCalls;

  const LlmMessage({this.content, this.toolCalls = const []});

  bool get hasToolCalls => toolCalls.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'role': 'assistant',
        if (content != null && content!.isNotEmpty) 'content': content,
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

  factory LlmConfig.openRouter({required String apiKey, String? model}) =>
      LlmConfig(
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: apiKey,
        model: model ?? 'poolside/laguna-xs-2.1:free',
      );
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
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'tools': tools.map((t) => t.toJson()).toList(),
      'tool_choice': 'auto',
    };

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

    final rawCalls = message['tool_calls'] as List<dynamic>? ?? const [];
    final toolCalls = rawCalls.map((raw) {
      final call = raw as Map<String, dynamic>;
      final fn = call['function'] as Map<String, dynamic>;
      return ToolCall(
        id: call['id'] as String,
        name: fn['name'] as String,
        arguments: jsonDecode(fn['arguments'] as String? ?? '{}')
            as Map<String, dynamic>,
      );
    }).toList();

    return LlmMessage(
      content: message['content'] as String?,
      toolCalls: toolCalls,
    );
  }

  void close() => _client.close();
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);

  @override
  String toString() => message;
}
