import 'dart:convert';

import 'package:handy_flutter/llm/llm_client.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

String _sseEvent(Map<String, dynamic> data) => 'data: ${jsonEncode(data)}\n\n';

class _StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  _StreamingClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);

  @override
  void close() {}
}

void main() {
  test('streams text and accumulates fragmented tool calls', () async {
    final toolArguments = jsonEncode({'path': 'README.md'});
    final responseChunks = [
      utf8.encode(': OPENROUTER PROCESSING\n\n'),
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {
                'reasoning': 'thinking',
                'reasoning_details': [
                  {
                    'type': 'reasoning.text',
                    'id': 'reasoning_1',
                    'text': 'Think ',
                  },
                ],
              },
            },
          ],
        }),
      ),
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {
                'reasoning': ' more',
                'reasoning_details': [
                  {
                    'type': 'reasoning.text',
                    'id': 'reasoning_1',
                    'text': 'more carefully.',
                  },
                ],
              },
            },
          ],
        }),
      ),
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {'content': 'Hello'},
            },
          ],
        }),
      ),
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {
                      'name': 'read',
                      'arguments': toolArguments.substring(0, 10),
                    },
                  },
                ],
              },
            },
          ],
        }),
      ),
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': toolArguments.substring(10)},
                  },
                ],
              },
            },
          ],
        }),
      ),
      utf8.encode('data: [DONE]\n\n'),
    ];

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['stream'], isTrue);
        return http.StreamedResponse(
          Stream.fromIterable(responseChunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final deltas = <String>[];
    var reasoningSignals = 0;
    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hello'},
      ],
      onTextDelta: deltas.add,
      onReasoningDelta: () => reasoningSignals++,
    );
    client.close();

    expect(deltas, ['Hello']);
    expect(reasoningSignals, 2);
    expect(result.reasoning, 'thinking more');
    expect(result.reasoningDetails.single['text'], 'Think more carefully.');
    expect(result.content, 'Hello');
    expect(result.toolCalls, hasLength(1));
    expect(result.toolCalls.single.id, 'call_1');
    expect(result.toolCalls.single.name, 'read');
    expect(result.toolCalls.single.arguments, {'path': 'README.md'});
  });
}
