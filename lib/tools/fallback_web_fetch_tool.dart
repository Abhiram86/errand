import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:html2md/html2md.dart' as html2md;
import 'package:reader_mode/reader_mode.dart' as rm;

import '../agent/tool.dart';
import '../services/tool_output_file_service.dart';
import '../types/tool.dart';

const kMaxWebFetchStoredChars = 100 * 1024;

/// Maximum raw HTTP response bytes allowed (5MB). Prevents downloading massive
/// files or unbounded streams into device RAM.
const kMaxRawWebFetchBytes = 5 * 1024 * 1024;
const _defaultInactivityTimeout = Duration(seconds: 10);
const _defaultTimeout = Duration(seconds: 20);

/// A zero-key on-device fallback for `webfetch`.
///
/// Fetches the URL directly via HTTP GET and uses Mozilla's Readability
/// algorithm ([rm.parse]) + [html2md.convert] to produce clean Markdown
/// without requiring third-party extraction APIs.
Tool fallbackWebFetchTool({
  http.Client? client,
  Duration inactivityTimeout = _defaultInactivityTimeout,
  Duration totalTimeout = _defaultTimeout,
  int maxRawBytes = kMaxRawWebFetchBytes,
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

      final httpClient = client ?? http.Client();
      final ownsClient = client == null;

      try {
        final request = http.Request('GET', uri);
        request.headers.addAll(const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5',
        });

        final streamed = await httpClient.send(request).timeout(inactivityTimeout);

        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          return ToolCallResult.failure(
            call.id,
            'Web fetch failed: HTTP ${streamed.statusCode} (${streamed.reasonPhrase ?? 'Error'})',
          );
        }

        final stream = streamed.stream.timeout(
          inactivityTimeout,
          onTimeout: (sink) => sink.addError(
            TimeoutException('Web fetch stream stalled (inactivity timeout)'),
          ),
        );

        final bytesBuilder = BytesBuilder(copy: false);
        var exceededCap = false;

        // Note: .timeout() abandons the loop but does not cancel the HTTP
        // subscription; the stream drains until GC. Bounded by maxRawBytes
        // in RAM regardless, so the exposure is transient bandwidth only.
        await Future.sync(() async {
          await for (final chunk in stream) {
            if (bytesBuilder.length + chunk.length > maxRawBytes) {
              final remaining = maxRawBytes - bytesBuilder.length;
              if (remaining > 0) {
                bytesBuilder.add(chunk.sublist(0, remaining));
              }
              exceededCap = true;
              break;
            }
            bytesBuilder.add(chunk);
          }
        }).timeout(totalTimeout);

        final rawBytes = bytesBuilder.takeBytes();
        final responseBody = utf8.decode(rawBytes, allowMalformed: true);

        var content = '';
        final contentType =
            streamed.headers['content-type']?.toLowerCase() ?? '';
        final isHtml = contentType.isEmpty ||
            contentType.contains('text/html') ||
            contentType.contains('application/xhtml+xml');

        if (isHtml) {
          try {
            final article = rm.parse(responseBody, baseUri: uri.toString());
            if (article != null) {
              if (article.content.isNotEmpty) {
                content = html2md.convert(article.content).trim();
              } else if (article.textContent.isNotEmpty) {
                content = article.textContent.trim();
              }
              if (article.title.isNotEmpty &&
                  !content.startsWith('# ${article.title}')) {
                content = '# ${article.title}\n\n$content';
              }
            }
          } catch (_) {
            // Reader mode parse failure - fall through to direct html2md
          }

          if (content.isEmpty) {
            content = html2md.convert(responseBody).trim();
          }
        } else {
          content = responseBody.trim();
        }

        if (content.isEmpty) {
          return ToolCallResult.failure(
            call.id,
            'No readable content found for $rawUrl.',
          );
        }

        if (content.length > kMaxWebFetchStoredChars) {
          content =
              '${content.substring(0, kMaxWebFetchStoredChars)}\n\n[... web content truncated at $kMaxWebFetchStoredChars chars ...]';
        }

        if (exceededCap) {
          content =
              '$content\n\n[Note: raw webpage exceeded ${(maxRawBytes ~/ (1024 * 1024))}MB cap and was truncated before parsing.]';
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
        if (ownsClient) {
          httpClient.close();
        }
      }
    },
  );
}
