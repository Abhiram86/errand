import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/types/tool.dart';

/// P2b act tool (Tier A, Draft-mode): semantic injection only — tap by label,
/// type into the focused field, scroll. No coordinate taps exist at all.
///
/// Consent model (Deny/Draft/Send) enforced structurally in v1 — no approval
/// UI over other apps:
/// - `tap`  : REVERSIBLE actions run; commit-looking controls are REFUSED
/// - `type` : always allowed (typing IS drafting); password fields refused
///            natively, and SET_TEXT never triggers enter-to-send
/// - `scroll`: always allowed (navigation-grade)
///
/// The rule: *the agent prepares, the user sends.* Upgrading specific
/// committing actions to auto-run (the "Send" tier) is future work behind an
/// explicit per-action user opt-in.
Tool actTool({A11yService? service}) {
  final svc = service ?? A11yService();

  return Tool(
    name: 'act',
    description:
        'Interact with the current phone screen: tap a button/link by its exact '
        'label from the screen outline, type text into the focused input field '
        '(replaces field content — include any existing text you want to keep), '
        'or scroll up/down. DRAFT POLICY: Errand prepares, the user sends. Taps on '
        'final-commit controls (Send/Post/Pay/Delete/Confirm...) are refused — '
        'tell the user to review and press those themselves. Typing never submits '
        'anything. Requires screen access to be enabled (same as the screen tool).',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['tap', 'type', 'scroll'],
          'description':
              'tap = click a labeled control (use "label"), type = set focused '
              'field content (use "text"), scroll = scroll the page (use "direction")',
        },
        'label': {
          'type': 'string',
          'description':
              'Exact visible label of the button/link to tap, as shown in the '
              'screen outline (e.g. "Allow", "Next", a chat name)',
        },
        'exact': {
          'type': 'boolean',
          'description':
              'Require an exact label match instead of best-match '
              '(default false). Prefer true when several elements share words.',
        },
        'text': {
          'type': 'string',
          'description':
              'Full new content for the focused editable field. REPLACES existing '
              'content — read the outline first and include any text to keep.',
        },
        'direction': {
          'type': 'string',
          'enum': ['up', 'down'],
          'description': 'Scroll direction for action:"scroll" (default down)',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      try {
        return await handleActAction(call, svc);
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Act failed: $e');
      }
    },
  );
}

Future<ToolCallResult> handleActAction(ToolCall call, A11yService svc) async {
  final action = call.arguments['action'] as String?;
  if (action == null || action.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing required argument: action');
  }

  // Availability gate — same honest failure as the screen tool.
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
    case 'tap':
      return _tap(call, svc);
    case 'type':
      return _type(call, svc);
    case 'scroll':
      return _scroll(call, svc);
    default:
      return ToolCallResult.failure(call.id, 'Unknown act action: $action');
  }
}

// ---- Draft policy ----------------------------------------------------------
//
// Word-boundary match so "send" refuses "Send message" but not "P.S." noise or
// "Sender address". Conservative list: false refusals annoy, missed commits
// cost money/trust.

const kCommitWords = <String>{
  // Messaging/social commits
  'send', 'post', 'publish', 'tweet', 'reply-all',
  // Money & orders
  'pay', 'buy', 'purchase', 'checkout', 'order', 'transfer', 'subscribe',
  // Irreversible / consent
  'delete', 'remove', 'uninstall', 'confirm', 'agree', 'accept', 'approve',
  'authorize', 'sign',
};

bool looksLikeCommitAction(String label) {
  // Keep hyphens inside tokens so 'reply-all' can match its list entry;
  // every other non-letter becomes a separator.
  final words = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z\s-]'), ' ')
      .split(RegExp(r'\s+'));
  bool hit(String word) =>
      kCommitWords.contains(word) ||
      // Hyphenated compounds count segment-wise too: 'confirm-order' must
      // refuse just like 'confirm'.
      word.split('-').any(kCommitWords.contains);
  return words.any(hit);
}

// ---- Handlers ---------------------------------------------------------------

Future<ToolCallResult> _tap(ToolCall call, A11yService svc) async {
  final label = (call.arguments['label'] as String?)?.trim();
  if (label == null || label.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'Missing required argument: label. Re-read the screen and use the exact '
      'visible label.',
    );
  }

  if (looksLikeCommitAction(label)) {
    return ToolCallResult.failure(
      call.id,
      'Refusing to tap "$label" — it looks like a final-commit control. Draft '
      'policy: Errand prepares, the USER presses Send/Confirm/Pay/etc. Prepare '
      'everything up to that point, then tell the user to do the last step.',
    );
  }

  final exact = call.arguments['exact'] == true;
  final res = await svc.tapByText(label, exact: exact);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Tap failed for "$label".',
    );
  }
  return ToolCallResult(id: call.id, ok: true, output: res['message'] as String? ?? '');
}

Future<ToolCallResult> _type(ToolCall call, A11yService svc) async {
  final text = call.arguments['text'];
  if (text is! String || text.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'Missing required argument: text. To clear a field pass a single space.',
    );
  }

  final res = await svc.typeText(text);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Could not type into the focused field.',
    );
  }
  return ToolCallResult(
    id: call.id,
    ok: true,
    output:
        '${res['message']} Field now contains ${text.length} chars. This is a '
        'DRAFT — do not look for a send button; the user will submit.',
  );
}

Future<ToolCallResult> _scroll(ToolCall call, A11yService svc) async {
  final direction = (call.arguments['direction'] as String?) ?? 'down';
  if (direction != 'up' && direction != 'down') {
    return ToolCallResult.failure(call.id, 'direction must be "up" or "down"');
  }

  final res = await svc.scroll(down: direction == 'down');
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Scroll failed.',
    );
  }
  return ToolCallResult(id: call.id, ok: true, output: res['message'] as String? ?? '');
}
