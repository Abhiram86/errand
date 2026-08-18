import '../agent/tool.dart';
import '../services/tavily_client.dart';
import '../types/tool.dart';

const kMaxWebSearchContentChars = 1200;
const kMaxWebFetchContentChars = 20000;

Tool webSearchTavilyTool({TavilyClient? client}) {
  final tavily = client ?? TavilyClient(apiKey: kTavilyApiKey);

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

        return ToolCallResult(id: call.id, ok: true, output: output.toString());
      } catch (error) {
        return ToolCallResult.failure(call.id, 'Web search failed: $error');
      }
    },
  );
}

Tool webFetchTool({TavilyClient? client}) {
  final tavily = client ?? TavilyClient(apiKey: kTavilyApiKey);

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

        return ToolCallResult(
          id: call.id,
          ok: true,
          output:
              'Source: $rawUrl\n\n${_truncate(content, kMaxWebFetchContentChars)}',
        );
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
