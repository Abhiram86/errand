import 'dart:convert';

import 'package:errand/llm/llm_client.dart';
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

  test('chatStream retries on 429 and succeeds on subsequent attempt', () async {
    var attempts = 0;
    final successChunks = [
      utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Success after retry'},
          },
        ],
      })),
      utf8.encode('data: [DONE]\n\n'),
    ];

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1/',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('Too many requests')),
            429,
            headers: const {'retry-after': '0'},
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable(successChunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final deltas = <String>[];
    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
      onTextDelta: deltas.add,
    );

    expect(attempts, 2);
    expect(result.content, 'Success after retry');
  });

  test('chatStream handles tool call chunks where subsequent deltas omit index', () async {
    final chunks = [
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'read', 'arguments': '{"pa'},
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
                    // index omitted by proxy!
                    'function': {'arguments': 'th": "a.txt"}'},
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
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'read a.txt'},
      ],
      onTextDelta: (_) {},
    );

    expect(result.toolCalls, hasLength(1));
    expect(result.toolCalls.single.id, 'call_1');
    expect(result.toolCalls.single.name, 'read');
    expect(result.toolCalls.single.arguments, {'path': 'a.txt'});
  });

  test('chatStream surfaces string error payload as LlmException', () async {
    final chunks = [
      utf8.encode('data: {"error": "Upstream rate limit exceeded"}\n\n'),
      utf8.encode('data: [DONE]\n\n'),
    ];

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    expect(
      () => client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.message,
          'message',
          'Upstream rate limit exceeded',
        ),
      ),
    );
  });

  test('chat throws LlmException when choices is empty', () async {
    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"choices": []}')),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    expect(
      () => client.chat(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
      ),
      throwsA(isA<LlmException>()),
    );
  });

  test('chatStream throws when model returns an empty response', () async {
    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    expect(
      () => client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.message,
          'message',
          contains('empty response'),
        ),
      ),
    );
  });

  test('chatStream catches choice-level error object', () async {
    final chunks = [
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'index': 0,
              'error': {'message': 'Provider crashed mid-generation'},
            },
          ],
        }),
      ),
    ];

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    expect(
      () => client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.message,
          'message',
          'Provider crashed mid-generation',
        ),
      ),
    );
  });

  test('chatStream catches finish_reason == error', () async {
    final chunks = [
      utf8.encode(
        _sseEvent({
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'Partial text'},
              'finish_reason': 'error',
            },
          ],
        }),
      ),
    ];

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      client: _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    expect(
      () => client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.message,
          'message',
          contains('finish_reason: error'),
        ),
      ),
    );
  });

  test('chatStream retries on mid-stream failure and invokes onReset', () async {
    var attempts = 0;
    var resetCount = 0;
    final accumulatedDeltas = <String>[];

    Stream<List<int>> createFailingStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Partial chunk '},
          },
        ],
      }));
      throw http.ClientException('Connection closed mid-stream');
    }

    Stream<List<int>> createSuccessStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Full successful message'},
          },
        ],
      }));
      yield utf8.encode('data: [DONE]\n\n');
    }

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
            createFailingStream(),
            200,
            headers: const {'content-type': 'text/event-stream'},
          );
        }
        return http.StreamedResponse(
          createSuccessStream(),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
      onTextDelta: accumulatedDeltas.add,
      onReset: () {
        resetCount++;
        accumulatedDeltas.clear();
      },
    );

    expect(attempts, 2);
    expect(resetCount, 1);
    expect(accumulatedDeltas, ['Full successful message']);
    expect(result.content, 'Full successful message');
  });

  test('chatStream fails with LlmException after 3 mid-stream failures', () async {
    var attempts = 0;
    var resetCount = 0;

    Stream<List<int>> createFailingStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Partial chunk'},
          },
        ],
      }));
      throw http.ClientException('Connection dropped');
    }

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        return http.StreamedResponse(
          createFailingStream(),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    await expectLater(
      client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
        onReset: () => resetCount++,
      ),
      throwsA(
        isA<LlmException>()
            .having((e) => e.transport, 'transport', isTrue)
            .having((e) => e.message, 'message', contains('Connection dropped')),
      ),
    );

    expect(attempts, 3);
    expect(resetCount, 2);
  });

  test('chatStream resets budget when a retry gets further before failing',
      () async {
    var attempts = 0;
    var resetCount = 0;
    final accumulatedDeltas = <String>[];

    Stream<List<int>> failingStream(String content) async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': content},
          },
        ],
      }));
      throw http.ClientException('Connection dropped');
    }

    Stream<List<int>> successStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Recovered'},
          },
        ],
      }));
      yield utf8.encode('data: [DONE]\n\n');
    }

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        // Each attempt gets strictly further before the cut.
        if (attempts <= 3) {
          return http.StreamedResponse(
            failingStream('x' * (attempts * 5)),
            200,
            headers: const {'content-type': 'text/event-stream'},
          );
        }
        return http.StreamedResponse(
          successStream(),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
      onTextDelta: accumulatedDeltas.add,
      onReset: () {
        resetCount++;
        accumulatedDeltas.clear();
      },
    );

    // Old fixed budget would have thrown after 3; forward progress earns a
    // 4th attempt which succeeds here.
    expect(attempts, 4);
    expect(resetCount, 3);
    expect(accumulatedDeltas, ['Recovered']);
    expect(result.content, 'Recovered');
  });

  test('chatStream skips onReset when the failed attempt had no partial data',      () async {
    var attempts = 0;
    var resetCount = 0;

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('Too many requests')),
            429,
            headers: const {'retry-after': '0'},
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode(_sseEvent({
              'choices': [
                {
                  'delta': {'content': 'Success after retry'},
                },
              ],
            })),
            utf8.encode('data: [DONE]\n\n'),
          ]),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
      onTextDelta: (_) {},
      onReset: () => resetCount++,
    );

    expect(attempts, 2);
    expect(resetCount, 0);
    expect(result.content, 'Success after retry');
  });

  test('chatStream caps total attempts despite continuous forward progress',
      () async {
    var attempts = 0;

    Stream<List<int>> failingStream(String content) async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': content},
          },
        ],
      }));
      throw http.ClientException('Connection dropped again');
    }

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        return http.StreamedResponse(
          failingStream('x' * (attempts * 5)),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    await expectLater(
      client.chatStream(
        messages: const [
          {'role': 'user', 'content': 'Hi'},
        ],
        onTextDelta: (_) {},
      ),
      throwsA(
        isA<LlmException>()
            .having((e) => e.transport, 'transport', isTrue)
            .having(
              (e) => e.message,
              'message',
              contains('Stream failed repeatedly'),
            ),
      ),
    );

    expect(attempts, 10);
  });

  test('chatStream reports each redial via onRetry with attempt and reason',
      () async {
    var attempts = 0;
    final retries = <String>[];

    Stream<List<int>> createFailingStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Partial chunk '},
          },
        ],
      }));
      throw http.ClientException('Connection closed mid-stream');
    }

    Stream<List<int>> createSuccessStream() async* {
      yield utf8.encode(_sseEvent({
        'choices': [
          {
            'delta': {'content': 'Recovered'},
          },
        ],
      }));
      yield utf8.encode('data: [DONE]\n\n');
    }

    final client = LlmClient(
      config: const LlmConfig(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
      backoffDuration: (_) => Duration.zero,
      client: _StreamingClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
            createFailingStream(),
            200,
            headers: const {'content-type': 'text/event-stream'},
          );
        }
        return http.StreamedResponse(
          createSuccessStream(),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await client.chatStream(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
      onTextDelta: (_) {},
      onRetry: (attempt, reason) => retries.add('$attempt:$reason'),
    );

    expect(attempts, 2);
    expect(retries, hasLength(1));
    expect(retries.single.startsWith('2:'), isTrue);
    expect(retries.single, contains('Connection lost'));
    expect(result.content, 'Recovered');
  });

  test('cleanErrorMessage formats JSON, HTML, and status codes cleanly', () {
    expect(
      cleanErrorMessage(
        500,
        '{"error": {"message": "Model is unavailable", "code": "unavailable"}}',
      ),
      'HTTP 500: Model is unavailable',
    );

    expect(
      cleanErrorMessage(
        502,
        '<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body>Raw HTML page</body></html>',
      ),
      'HTTP 502: Bad Gateway',
    );

    expect(
      cleanErrorMessage(429, ''),
      'HTTP 429: Rate limit exceeded',
    );

    expect(
      cleanErrorMessage(401, 'Unauthorized'),
      'HTTP 401: Unauthorized',
    );
  });
}
