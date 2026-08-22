import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/types/tool.dart';

/// P2a screen tool (Tier S): read-only access to the active window's
/// accessibility tree plus global navigation actions. No injection — that is
/// Tier A and gated.
///
/// Same layered design as the intent tool:
/// curated actions -> honest failure with enablement guidance.
Tool screenTool({A11yService? service}) {
  final svc = service ?? A11yService();

  return Tool(
    name: 'screen',
    description:
        'Reads the current phone screen or performs system navigation. '
        'Use action "read" to get a text outline of what is on screen right now '
        '(buttons, labels, editable fields) — use it to answer "what\'s on my screen" '
        'or to check a result after opening an app. Use action "global" for '
        'system navigation: back, home, recents, notifications shade, quick settings, '
        'lock_screen. Requires the user to have enabled Errand in Accessibility '
        'settings; if unavailable, tell the user how to enable it instead of retrying.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['read', 'global'],
          'description':
              'read = describe current screen contents; global = perform a '
              'navigation action (use "name")',
        },
        'name': {
          'type': 'string',
          'enum': [
            'back',
            'home',
            'recents',
            'notifications',
            'quick_settings',
            'lock_screen'
          ],
          'description': 'Navigation action for action:"global"',
        },
        'max_nodes': {
          'type': 'integer',
          'description':
              'Cap on UI nodes returned for read (default 300). Lower it if you '
              'only need a quick summary.',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      try {
        return await handleScreenAction(call, svc);
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Screen failed: $e');
      }
    },
  );
}

Future<ToolCallResult> handleScreenAction(ToolCall call, A11yService svc) async {
  final action = call.arguments['action'] as String?;
  if (action == null || action.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing required argument: action');
  }

  // Availability gate — honest failure with actionable guidance.
  final enabled = await svc.isEnabled();
  if (!enabled) {
    final restricted = await svc.isRestricted();
    return ToolCallResult.failure(
      call.id,
      restricted
          ? 'Screen access is blocked by Android ("Restricted setting") because '
              'Errand was installed outside an app store. Fix: Settings > Apps > '
              'Errand > three-dot menu > Allow restricted settings, then enable '
              'Errand in Settings > Accessibility.'
          : 'Screen access is not enabled. Ask the user to open Settings > '
              'Accessibility > downloaded apps > Errand and turn the service on.',
    );
  }

  switch (action) {
    case 'read':
      return _read(call, svc);
    case 'global':
      return _global(call, svc);
    default:
      return ToolCallResult.failure(call.id, 'Unknown screen action: $action');
  }
}

Future<ToolCallResult> _read(ToolCall call, A11yService svc) async {
  final maxNodesRaw = call.arguments['max_nodes'];
  final maxNodes =
      maxNodesRaw is int && maxNodesRaw > 0 ? maxNodesRaw.clamp(10, 1000) : 300;

  final res = await svc.readScreen(maxNodes: maxNodes);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Could not read the active window.',
    );
  }

  var outline = res['outline'] as String? ?? '';
  if (res['truncated'] == true) {
    outline +=
        '\n[...outline truncated (node/char cap). Re-read with a higher '
        'max_nodes for more detail, or ask the user about anything not shown.]';
  }
  // Hard char clamp mirrors the per-tool-result budget in context_budget.
  const maxChars = 24000;
  if (outline.length > maxChars) {
    outline = '${outline.substring(0, maxChars)}\n[...truncated]';
  }

  return ToolCallResult(
    id: call.id,
    ok: true,
    output: outline,
  );
}

Future<ToolCallResult> _global(ToolCall call, A11yService svc) async {
  final name = call.arguments['name'] as String?;
  if (name == null || name.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing required argument: name (for global)');
  }

  final err = await svc.globalAction(name);
  if (err != null) {
    return ToolCallResult.failure(call.id, err);
  }
  return ToolCallResult(id: call.id, ok: true, output: '$name done');
}
