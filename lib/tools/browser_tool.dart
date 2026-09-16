import 'dart:convert';

import '../agent/tool.dart';
import '../services/browser_service.dart';
import '../types/tool.dart';

/// Creates the `browser` tool group, exposing embedded web automation functions:
/// - `open` (`browser.open`): navigate to a URL and display the browser
/// - `close` (`browser.close`): dismiss the browser
/// - `reload` (`browser.reload`): reload the current page
/// - `snapshot` (`browser.snapshot`): extract a token-efficient DOM outline with interactive refs
/// - `extract_text` (`browser.extract_text`): extract clean Markdown text of the page via html2md
/// - `execute_dom_js` (`browser.execute_dom_js`): evaluate arbitrary JS in the DOM
/// - `act` (`browser.act`): perform clicks, typing, or scrolling
/// - `screenshot` (`browser.screenshot`): capture the visible viewport
Tool browserTool({BrowserService? browserService}) {
  final service = browserService ?? BrowserService.instance;

  return Tool(
    name: 'browser',
    description:
        'Embedded web browser tool group to inspect and interact with websites. '
        'Functions: '
        'open (load a URL and show the browser), '
        'close (hide the browser view), '
        'reload (refresh the current page), '
        'snapshot (extract a structured DOM outline with interactive element refs [e1], [e2] and text preview), '
        'extract_text (extract clean Markdown text of the page via html2md), '
        'execute_dom_js (evaluate custom JavaScript in the page DOM), '
        'act (click, type, or scroll using element refs or selectors), '
        'screenshot (capture the visible viewport).',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'open',
            'close',
            'reload',
            'snapshot',
            'extract_text',
            'execute_dom_js',
            'act',
            'screenshot',
          ],
          'description':
              'The browser action to execute: '
              'open, close, reload, snapshot, extract_text, execute_dom_js, act, or screenshot.',
        },
        'url': {
          'type': 'string',
          'description': 'Target URL for action:"open".',
        },
        'full_dump': {
          'type': 'boolean',
          'description':
              'When true for action:"snapshot", returns the raw HTML DOM of the page instead of the structured element outline.',
        },
        'dump_offset': {
          'type': 'integer',
          'description':
              'Character offset for full_dump pagination (default 0).',
        },
        'dump_limit': {
          'type': 'integer',
          'description':
              'Maximum characters for full_dump chunk (default 100000, max 200000).',
        },
        'max_chars': {
          'type': 'integer',
          'description':
              'Maximum characters for action:"extract_text" (default 150000) or action:"execute_dom_js" (default 50000).',
        },
        'script': {
          'type': 'string',
          'description':
              'JavaScript expression to evaluate for action:"execute_dom_js".',
        },
        'act_action': {
          'type': 'string',
          'enum': ['click', 'type', 'select', 'get', 'scroll'],
          'description':
              'Interaction type for action:"act": click, type, select (dropdowns), get (read state), or scroll.',
        },
        'ref': {
          'type': 'string',
          'description':
              'Element agent ID (from snapshot, e.g. "e1", "e2") or element id attribute for action:"act" or action:"snapshot".',
        },
        'selector': {
          'type': 'string',
          'description': 'CSS selector for action:"act", action:"snapshot", or action:"extract_text".',
        },
        'text': {
          'type': 'string',
          'description':
              'Text to input for act_action:"type" or option value/label to select for act_action:"select".',
        },
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'top', 'bottom'],
          'description':
              'Scroll direction for action:"act" with act_action:"scroll" (default "down").',
        },
        'settle_ms': {
          'type': 'integer',
          'description':
              'Milliseconds to wait before performing read activities (snapshot, extract_text, screenshot) '
              'so dynamic DOM/SPA content has time to render (default 350). Set to 0 to read immediately.',
        },
        'clear': {
          'type': 'boolean',
          'description':
              'Whether to reset the browser to about:blank on action:"close" (default false).',
        },
      },
    },
    handler: (call) async {
      final args = call.arguments;

      // Extract action from args or from prefix calls like browser.open / browser_open
      var action = args['action']?.toString().trim().toLowerCase();
      var actAction = (args['act_action'] ??
              args['interaction'] ??
              args['sub_action'] ??
              args['act'])
          ?.toString()
          .trim()
          .toLowerCase();

      if (action == null || action.isEmpty) {
        final callName = call.name.toLowerCase();
        if (callName.contains('open')) {
          action = 'open';
        } else if (callName.contains('close')) {
          action = 'close';
        } else if (callName.contains('reload') || callName.contains('refresh')) {
          action = 'reload';
        } else if (callName.contains('snapshot') || callName.contains('inspect')) {
          action = 'snapshot';
        } else if (callName.contains('extract') ||
            callName.contains('text') ||
            callName.contains('markdown')) {
          action = 'extract_text';
        } else if (callName.contains('execute') ||
            callName.contains('eval') ||
            callName.contains('js')) {
          action = 'execute_dom_js';
        } else if (callName.contains('click')) {
          action = 'act';
          actAction = 'click';
        } else if (callName.contains('type') || callName.contains('input')) {
          action = 'act';
          actAction = 'type';
        } else if (callName.contains('select') || callName.contains('choose')) {
          action = 'act';
          actAction = 'select';
        } else if (callName.contains('get') || callName.contains('read_element')) {
          action = 'act';
          actAction = 'get';
        } else if (callName.contains('scroll')) {
          action = 'act';
          actAction = 'scroll';
        } else if (callName.contains('act')) {
          action = 'act';
        } else if (callName.contains('screenshot') || callName.contains('shot')) {
          action = 'screenshot';
        }
      }

      if (action == null || action.isEmpty) {
        return ToolCallResult.failure(
          call.id,
          'Missing "action" parameter. Specify one of: open, close, reload, snapshot, execute_dom_js, act, screenshot.',
        );
      }

      try {
        switch (action) {
          case 'open':
            final rawUrl = (args['url'] ?? args['uri'] ?? args['target'])?.toString().trim();
            if (rawUrl == null || rawUrl.isEmpty) {
              return ToolCallResult.failure(
                call.id,
                'URL parameter is required for browser open.',
              );
            }
            final pageInfo = await service.open(rawUrl);
            final buffer = StringBuffer();
            buffer.writeln('Opened browser at ${pageInfo.url}');
            if (pageInfo.title.isNotEmpty) {
              buffer.writeln('Page Title: ${pageInfo.title}');
            }
            buffer.writeln('Status: ${pageInfo.status}');
            if (pageInfo.status.startsWith('error:')) {
              return ToolCallResult.failure(
                call.id,
                'Failed to load page: ${pageInfo.status}',
              );
            }
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: buffer.toString().trim(),
            );

          case 'close':
            final clear = args['clear'] == true;
            await service.close(clear: clear);
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: 'Browser closed.',
            );

          case 'reload':
            await service.reload();
            final buffer = StringBuffer();
            buffer.writeln('Page reloaded.');
            if (service.currentUrl != null) {
              buffer.writeln('Current URL: ${service.currentUrl}');
            }
            if (service.currentTitle != null) {
              buffer.writeln('Title: ${service.currentTitle}');
            }
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: buffer.toString().trim(),
            );

          case 'snapshot':
            final settleMs = _parseSettleMs(args['settle_ms'] ?? args['settleMs'] ?? args['wait_ms']);
            if (settleMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: settleMs));
            }
            final fullDump = args['full_dump'] == true || args['fullDump'] == true;
            final dumpOffset = (args['dump_offset'] ?? args['offset']) as int? ?? 0;
            final dumpLimit = (args['dump_limit'] ?? args['limit']) as int? ?? 100000;
            final maxNodes = (args['max_nodes'] ?? args['maxNodes']) as int? ?? 200;
            final ref = args['ref']?.toString();
            final selector = (args['selector'] ?? args['target'])?.toString();
            final snapshotOutput = await service.snapshot(
              maxNodes: maxNodes,
              fullDump: fullDump,
              dumpOffset: dumpOffset,
              dumpLimit: dumpLimit,
              ref: ref,
              selector: selector,
            );
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: snapshotOutput,
            );

          case 'extract_text':
            final settleMs = _parseSettleMs(args['settle_ms'] ?? args['settleMs'] ?? args['wait_ms']);
            if (settleMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: settleMs));
            }
            final selector = (args['selector'] ?? args['target'])?.toString();
            final maxChars = (args['max_chars'] ?? args['maxChars']) as int? ?? 150000;
            final text = await service.extractText(selector: selector, maxChars: maxChars);
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: text,
            );

          case 'execute_dom_js':
            final script =
                (args['script'] ?? args['js'] ?? args['code'])?.toString();
            if (script == null || script.trim().isEmpty) {
              return ToolCallResult.failure(
                call.id,
                'Missing "script" parameter for execute_dom_js.',
              );
            }
            final maxChars = (args['max_chars'] ?? args['maxChars']) as int? ?? 50000;
            final result = await service.executeDomJs(script, maxChars: maxChars);
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: result,
            );

          case 'act':
            if (actAction == null || actAction.isEmpty) {
              if (args['click'] != null) {
                actAction = 'click';
              } else if (args['type'] != null) {
                actAction = 'type';
              } else if (args['select'] != null) {
                actAction = 'select';
              } else if (args['get'] != null || args['read'] != null) {
                actAction = 'get';
              } else if (args['scroll'] != null) {
                actAction = 'scroll';
              }
            }

            if (actAction == null || actAction.isEmpty) {
              return ToolCallResult.failure(
                call.id,
                'Missing interaction type for browser act. Specify act_action: "click", "type", "select", "get", or "scroll".',
              );
            }

            final ref = args['ref']?.toString();
            final selector = args['selector']?.toString();
            final text = (args['text'] ?? args['value'])?.toString();
            final direction = args['direction']?.toString();

            final actResult = await service.act(
              action: actAction,
              ref: ref,
              selector: selector,
              text: text,
              direction: direction,
            );
            return ToolCallResult(
              id: call.id,
              ok: true,
              output: actResult,
            );

          case 'screenshot':
            final settleMs = _parseSettleMs(args['settle_ms'] ?? args['settleMs'] ?? args['wait_ms']);
            if (settleMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: settleMs));
            }
            final bytes = await service.takeScreenshot();
            if (bytes == null || bytes.isEmpty) {
              return ToolCallResult.failure(
                call.id,
                'Failed to capture viewport screenshot.',
              );
            }
            final base64Data = base64Encode(bytes);
            return ToolCallResult(
              id: call.id,
              ok: true,
              output:
                  'Captured browser viewport screenshot (${bytes.lengthInBytes} bytes).',
              contentParts: [
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/png;base64,$base64Data',
                  },
                },
              ],
            );

          default:
            return ToolCallResult.failure(
              call.id,
              'Unknown browser action: "$action". Supported actions are: open, close, reload, snapshot, extract_text, execute_dom_js, act, screenshot.',
            );
        }
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Browser error ($action): $e');
      }
    },
  );
}

int _parseSettleMs(dynamic raw, {int defaultValue = 350}) {
  if (raw is num) {
    return raw.toInt().clamp(0, 10000);
  }
  return defaultValue;
}

/// Tool allowing direct extraction of clean Markdown text from the current browser page.
Tool extractTextTool({BrowserService? browserService}) {
  final service = browserService ?? BrowserService.instance;

  return Tool(
    name: 'extract_text',
    description:
        'Extracts clean Markdown text from the currently open browser web page using html2md. '
        'Ideal for reading articles, documentation, or search results without token or DOM outline bloat.',
    parameters: {
      'type': 'object',
      'properties': {
        'selector': {
          'type': 'string',
          'description':
              'Optional CSS selector to extract text from a specific element (e.g. "article", "main", "#content"). Defaults to entire page.',
        },
        'settle_ms': {
          'type': 'integer',
          'description':
              'Milliseconds to wait before extracting text so dynamic DOM/SPA content has time to render (default 350). Set to 0 to read immediately.',
        },
        'max_chars': {
          'type': 'integer',
          'description':
              'Maximum characters of HTML to extract before converting to markdown (default 150000).',
        },
      },
    },
    handler: (call) async {
      try {
        final settleMs = _parseSettleMs(
          call.arguments['settle_ms'] ??
              call.arguments['settleMs'] ??
              call.arguments['wait_ms'],
        );
        if (settleMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: settleMs));
        }
        final selector =
            (call.arguments['selector'] ?? call.arguments['target'])?.toString();
        final maxChars = (call.arguments['max_chars'] ?? call.arguments['maxChars']) as int? ?? 150000;
        final text = await service.extractText(selector: selector, maxChars: maxChars);
        return ToolCallResult(
          id: call.id,
          ok: true,
          output: text,
        );
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Extract text error: $e');
      }
    },
  );
}
