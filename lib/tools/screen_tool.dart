import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/intent_service.dart';
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
        '(interactive elements carry numeric refs [n] — address them via act '
        'ref:n; refs expire on every read, so re-read after navigation) and use it '
        'to answer "what\'s on my screen" or to check a result after opening an app. '
        'Use action "global" for '
        'system navigation: back, home, recents, notifications shade, quick settings, '
        'lock_screen. Requires the user to have enabled Errand in '
        'Accessibility settings; if unavailable, tell the user how to enable it '
        'instead of retrying.',
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
            'lock_screen',
            'return_to_errand',
          ],
          'description':
              'Navigation action for action:"global": back, home, recents, '
              'notifications, quick_settings, lock_screen, return_to_errand.',
        },
        'max_nodes': {
          'type': 'integer',
          'description':
              'Cap on UI nodes returned for read (default 300). Raise it only '
              'when a read reports the NODE cap was hit; raising it never '
              'changes a CHARACTER-capped result.',
        },
        'settle_ms': {
          'type': 'integer',
          'description':
              'Milliseconds to wait before reading (default 350). Raise to '
              '~800-1500 right after open_app/navigation so the new screen '
              'has time to render; reading too early returns stale content.',
        },
        'full': {
          'type': 'boolean',
          'description':
              'Set true ONLY when you believe an UNCHANGED result is stale '
              '(e.g. the app misbehaved). By default, unchanged screens return '
              'a one-line summary instead of a full outline — that is desired.',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      try {
        return await handleScreenAction(call, svc);
      } on A11yRequiredException {
        rethrow;
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

  // Availability gate: ensures enabled or throws A11yRequiredException to halt turn.
  await svc.ensureEnabled();

  switch (action) {
    case 'read':
      return _read(call, svc);
    case 'global':
      return _global(call, svc);
    default:
      return ToolCallResult.failure(
        call.id,
        'Unknown screen action "$action". Valid actions: read, global. '
        '(Note: "read" here reads THE SCREEN — it belongs to this tool, not the intent tool.)',
      );
  }
}

Future<ToolCallResult> _read(ToolCall call, A11yService svc) async {
  final maxNodesRaw = call.arguments['max_nodes'];
  final maxNodes =
      maxNodesRaw is int && maxNodesRaw > 0 ? maxNodesRaw.clamp(10, 1000) : 300;
  final settleMsRaw = call.arguments['settle_ms'];
  final settleMs =
      settleMsRaw is int && settleMsRaw > 0 ? settleMsRaw.clamp(0, 5000) : 350;
  final full = call.arguments['full'] == true;

  // Settle time: reading immediately after open_app/navigation returns the
  // previous screen. The default covers most transitions; the model raises
  // it when a first read came back stale.
  if (settleMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: settleMs));
  }

  final res = await svc.readScreen(maxNodes: maxNodes, full: full);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Could not read the active window.',
    );
  }

  // Verification re-read on an unchanged screen: one line instead of the
  // full outline — this is what keeps long screen flows from burning tokens.
  if (res['unchanged'] == true) {
    return ToolCallResult(
      id: call.id,
      ok: true,
      output:
          'UNCHANGED — screen is identical to your previous read; everything '
          'you saw earlier still applies. Do not re-read unless you perform '
          'an action. Pass full:true only if you believe the snapshot is stale.',
    );
  }

  var outline = res['outline'] as String? ?? '';
  if (res['truncated'] == true) {
    final capHit = res['capHit'] as String?;
    if (capHit == 'chars') {
      // Raising max_nodes cannot change a character-capped result — say so,
      // or the model burns turns retrying with bigger node caps.
      outline +=
          '\n[...outline truncated at the CHARACTER budget '
          '(${res['charsUsed']}/${res['maxChars']} chars; ${res['nodes']} nodes seen). '
          'Raising max_nodes will NOT change this. Some apps render body content '
          'in web views that expose little or no text to accessibility — ask the '
          'user for specifics instead of retrying.]';
    } else {
      outline +=
          '\n[...outline truncated at the NODE cap (${res['nodes']}/$maxNodes nodes). '
          'Re-read with a higher max_nodes for more detail.]';
    }
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

  if (name == 'return_to_errand') {
    await IntentService().bringToFront();
    return ToolCallResult(id: call.id, ok: true, output: 'return_to_errand done');
  }

  final err = await svc.globalAction(name);
  if (err != null) {
    return ToolCallResult.failure(call.id, err);
  }
  return ToolCallResult(id: call.id, ok: true, output: '$name done');
}
