import 'package:http/http.dart' as http;

import '../agent/tool.dart';
import '../services/app_settings.dart';
import '../services/tavily_client.dart';
import '../services/tool_output_file_service.dart';
import '../types/tool.dart';
import 'fallback_web_fetch_tool.dart';

const kMaxWebSearchContentChars = 1200;

/// Cap on extracted web content kept for spill (memory/disk guard). The
/// `Source:` header stays first so previews preserve it.
const kMaxWebFetchStoredChars = 100 * 1024;

/// Builds a [TavilyClient] from the key stored in app settings.
///
/// Resolved lazily PER CALL (not at registry construction) so saving a key
/// in Settings takes effect immediately without rebuilding the tool set.
/// Returns null when no key is configured — callers turn that into a clean
/// tool failure pointing at Settings.
TavilyClient? _resolveTavilyClient({
  TavilyClient? client,
  String? Function()? keyResolver,
}) {
  if (client != null) return client;
  try {
    final key = keyResolver != null
        ? keyResolver()
        : AppSettingsService.instance.tavilyKey?.trim();
    if (key == null || key.isEmpty) return null;
    return TavilyClient(apiKey: key);
  } catch (_) {
    return null;
  }
}

Tool webSearchTavilyTool({
  TavilyClient? client,
  String? Function()? keyResolver,
}) {
  return Tool(
    name: 'websearch',
    description:
        'Searches the web using Tavily and returns concise results with titles, '
        'URLs, and snippets. Use webfetch when the full content of a result '
        'is needed.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Search query'},
      },
      'required': ['query'],
    },
    handler: (call) async {
      final query = (call.arguments['query'] as String?)?.trim();
      if (query == null || query.isEmpty) {
        return ToolCallResult.failure(call.id, 'Query cannot be empty.');
      }
      final tavily = _resolveTavilyClient(
        client: client,
        keyResolver: keyResolver,
      );
      if (tavily == null) {
        final encodedQuery = Uri.encodeQueryComponent(query);
        return ToolCallResult.failure(
          call.id,
          'Tavily API key is not configured. Web search cannot be executed directly, '
          'but webfetch still works without an API key because a fallback implementation is active. '
          'You can use webfetch as web search via sites like '
          'https://lite.duckduckgo.com/lite/?q=$encodedQuery or other alternatives if rate limited.',
        );
      }

      try {
        final data = await tavily.search(query);
        final rawResults = data['results'];
        if (rawResults is! List || rawResults.isEmpty) {
          return ToolCallResult(
            id: call.id,
            ok: true,
            output: 'No web results found for "$query".',
          );
        }

        final output = StringBuffer('Web results for "$query":\n');
        var resultNumber = 0;
        for (final rawResult in rawResults) {
          if (rawResult is! Map) continue;
          final title = _stringValue(rawResult['title'], 'Untitled result');
          final url = _stringValue(rawResult['url'], 'URL unavailable');
          final content = _truncate(
            _stringValue(rawResult['content'], 'No snippet available.'),
            kMaxWebSearchContentChars,
          );
          resultNumber++;
          output
            ..writeln()
            ..writeln('$resultNumber. $title')
            ..writeln('URL: $url')
            ..writeln(content);
        }

        final finalOutput = await ToolOutputFileService.instance.processOutput(
          callId: call.id,
          output: output.toString(),
        );
        return ToolCallResult(id: call.id, ok: true, output: finalOutput);
      } catch (error) {
        final message = error.toString();
        if (message.contains('401') || message.contains('API key')) {
          final encodedQuery = Uri.encodeQueryComponent(query);
          return ToolCallResult.failure(
            call.id,
            'Web search failed ($message). Note that webfetch still works without an API key '
            'because a fallback implementation is active. You can use webfetch as web search '
            'via sites like https://lite.duckduckgo.com/lite/?q=$encodedQuery or other alternatives if rate limited.',
          );
        }
        return ToolCallResult.failure(call.id, 'Web search failed: $error');
      } finally {
        // Per-call client: release its socket pool immediately instead of
        // letting idle keep-alive connections accumulate across tool calls.
        tavily.close();
      }
    },
  );
}

Tool webFetchTool({
  TavilyClient? client,
  http.Client? fallbackClient,
  String? Function()? keyResolver,
}) {
  return Tool(
    name: 'webfetch',
    description:
        'Fetches a web page and extracts its readable content as Markdown. '
        'Use this after websearch when you need the full content of a specific '
        'URL. An optional query can focus extraction on relevant parts.',
    parameters: {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'The HTTP or HTTPS URL to fetch',
        },
        'query': {
          'type': 'string',
          'description':
              'Optional question or topic used to focus the extracted content',
        },
      },
      'required': ['url'],
    },
    handler: (call) async {
      final rawUrl = (call.arguments['url'] as String?)?.trim();
      if (rawUrl == null || rawUrl.isEmpty) {
        return ToolCallResult.failure(call.id, 'URL cannot be empty.');
      }

      final uri = Uri.tryParse(rawUrl);
      if (uri == null || !{'http', 'https'}.contains(uri.scheme)) {
        return ToolCallResult.failure(
          call.id,
          'URL must be a valid HTTP or HTTPS URL.',
        );
      }

      final query = (call.arguments['query'] as String?)?.trim();
      final tavily = _resolveTavilyClient(
        client: client,
        keyResolver: keyResolver,
      );

      // 1. First attempt: use Tavily if configured
      if (tavily != null) {
        try {
          final data = await tavily.extract(
            url: uri.toString(),
            query: query == null || query.isEmpty ? null : query,
          );
          final rawResults = data['results'];
          if (rawResults is List && rawResults.isNotEmpty) {
            final firstResult = rawResults.first;
            if (firstResult is Map) {
              var content = _stringValue(firstResult['raw_content'], '').trim();
              if (content.isNotEmpty) {
                if (content.length > kMaxWebFetchStoredChars) {
                  content =
                      '${content.substring(0, kMaxWebFetchStoredChars)}\n\n[... web content truncated at $kMaxWebFetchStoredChars chars ...]';
                }

                final rawText = 'Source: $rawUrl\n\n$content';
                final finalOutput =
                    await ToolOutputFileService.instance.processOutput(
                  callId: call.id,
                  output: rawText,
                );

                return ToolCallResult(
                  id: call.id,
                  ok: true,
                  output: finalOutput,
                );
              }
            }
          }
        } catch (_) {
          // Tavily failed (quota limit 429, timeout, network error) -> fall through to fallback
        } finally {
          tavily.close();
        }
      }

      // 2. Fallback: on-device readable Markdown extraction
      try {
        return await fallbackWebFetchTool(client: fallbackClient).handler(call);
      } catch (error) {
        return ToolCallResult.failure(call.id, 'Web fetch failed: $error');
      }
    },
  );
}

String _stringValue(Object? value, String fallback) {
  return value is String && value.isNotEmpty ? value : fallback;
}

String _truncate(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  return '${value.substring(0, maxChars)}\n\n[content truncated]';
}
