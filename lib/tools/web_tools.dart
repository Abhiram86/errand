import '../agent/tool.dart';
import '../services/app_settings.dart';
import '../services/tavily_client.dart';
import '../services/tool_output_file_service.dart';
import '../types/tool.dart';

const kMaxWebSearchContentChars = 1200;
const kMaxWebFetchContentChars = 20000;

/// Builds a [TavilyClient] from the key stored in app settings.
///
/// Resolved lazily PER CALL (not at registry construction) so saving a key
/// in Settings takes effect immediately without rebuilding the tool set.
/// Returns null when no key is configured — callers turn that into a clean
/// tool failure pointing at Settings.
TavilyClient? _resolveTavilyClient({TavilyClient? client}) {
  if (client != null) return client;
  final key = AppSettingsService.instance.tavilyKey?.trim();
  if (key == null || key.isEmpty) return null;
  return TavilyClient(apiKey: key);
}

Tool webSearchTavilyTool({TavilyClient? client}) {
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
      final tavily = _resolveTavilyClient(client: client);
      if (tavily == null) {
        return ToolCallResult.failure(
          call.id,
          'Tavily API key is not configured. Open Settings (gear icon) and '
          'add a Tavily key to enable web search.',
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
        return ToolCallResult.failure(call.id, 'Web search failed: $error');
      } finally {
        // Per-call client: release its socket pool immediately instead of
        // letting idle keep-alive connections accumulate across tool calls.
        tavily.close();
      }
    },
  );
}

Tool webFetchTool({TavilyClient? client}) {
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

      final tavily = _resolveTavilyClient(client: client);
      if (tavily == null) {
        return ToolCallResult.failure(
          call.id,
          'Tavily API key is not configured. Open Settings (gear icon) and '
          'add a Tavily key to enable web fetching.',
        );
      }

      try {
        final data = await tavily.extract(
          url: uri.toString(),
          query: query == null || query.isEmpty ? null : query,
        );
        final rawResults = data['results'];
        if (rawResults is! List || rawResults.isEmpty) {
          return ToolCallResult.failure(
            call.id,
            'Tavily could not extract content from $rawUrl.',
          );
        }

        final firstResult = rawResults.first;
        if (firstResult is! Map) {
          return ToolCallResult.failure(
            call.id,
            'Tavily returned an invalid extraction result for $rawUrl.',
          );
        }

        final content = _stringValue(firstResult['raw_content'], '').trim();
        if (content.isEmpty) {
          return ToolCallResult.failure(
            call.id,
            'Tavily returned no readable content for $rawUrl.',
          );
        }

        final rawText = 'Source: $rawUrl\n\n$content';
        final finalOutput = await ToolOutputFileService.instance.processOutput(
          callId: call.id,
          output: rawText,
        );

        return ToolCallResult(
          id: call.id,
          ok: true,
          output: finalOutput,
        );
      } catch (error) {
        return ToolCallResult.failure(call.id, 'Web fetch failed: $error');
      } finally {
        tavily.close();
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
