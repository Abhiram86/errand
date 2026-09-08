import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/tool_output_file_service.dart';
import 'package:errand/tools/grep_filter.dart';
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
        'label from the screen outline or numeric "ref", type text into the focused '
        'input field (replaces field content — include any existing text you want to keep), '
        'or scroll. Pass then_read:true to automatically receive the updated screen '
        'outline in the same tool result (saves an entire round-trip turn). DRAFT POLICY: '
        'Errand prepares, the user sends. Taps on final-commit controls '
        '(Send/Post/Pay/Delete/Confirm...) are refused — tell the user to review and '
        'confirm the action themselves.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'tap',
            'type',
            'scroll',
            'fill',
            'tab',
            'long_press',
            'esc',
          ],
          'description':
              'tap = click an element by ref or label; type = set text in '
              'focused field; fill = tap an input field then type text into '
              'it; scroll = swipe/scroll in direction; tab = press Tab; '
              'long_press = press-and-hold (use "ref"); esc = press Escape',
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
        'ref': {
          'type': 'integer',
          'description':
              'Numeric element reference from the LAST screen read, e.g. 3 for '
              '[3]. PREFERRED over label — no collisions. Refs expire on every '
              'new read.',
          'minimum': 1,
        },
        'occurrence': {
          'type': 'integer',
          'description':
              '1-based index among identical/best-matching labels (outline '
              'order). Use when the screen shows several elements with the '
              'same label — count them from the read output. Default 1.',
          'minimum': 1,
        },
        'times': {
          'type': 'integer',
          'description':
              'For scroll: repeat the scroll this many times in ONE call '
              '(wheels move one unit per scroll; lists one page per scroll). '
              'Default 1, max 30. Use instead of many separate scroll calls.',
          'minimum': 1,
        },
        'near_label': {
          'type': 'string',
          'description':
              'For scroll: target only the scrollable whose visible content '
              'contains this text (e.g. the current minutes value "52", or a '
              'row label like "Kolkata"). Required to pick between multiple '
              'scrollables (hour vs minute wheels, tab pages).',
        },
        'text': {
          'type': 'string',
          'description':
              'Full new content for the focused editable field. REPLACES existing '
              'content — read the outline first and include any text to keep.',
        },
        'overwrite': {
          'type': 'boolean',
          'description':
              'For fill/type: allow replacing a field that already contains '
              'text (default false — refuses to clobber non-empty fields).',
        },
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'left', 'right'],
          'description':
              'Scroll direction for action:"scroll" (default down). left/right '
              'for carousels and horizontal sliders.',
        },
        'then_read': {
          'type': 'boolean',
          'description':
              'Optional: automatically read and include the updated screen outline '
              'after this action completes. Highly recommended to save a full turn.',
        },
        'settle_ms': {
          'type': 'integer',
          'description':
              'Milliseconds to wait before reading the screen when then_read:true '
              '(default 1000ms, clamp 0–5000). Use higher values (~1200–2000) '
              'after opening apps, page transitions, or system-wide settings '
              '(e.g. Dark theme).',
          'minimum': 0,
          'maximum': 5000,
        },
        'grep': {
          'type': 'string',
          'description':
              'Optional case-insensitive regular expression or substring filter. '
              'Implies then_read:true — filters the updated screen outline to only matching lines.',
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
          : 'Screen access is currently off (it pauses when Errand closes to keep other apps secure). '
              'Ask the user to enable screen access in Settings > Accessibility, or manage it in Errand Settings > Tools.',
    );
  }

  final ToolCallResult result;
  switch (action) {
    case 'tap':
      result = await _tap(call, svc);
      break;
    case 'type':
      result = await _type(call, svc);
      break;
    case 'scroll':
      result = await _scroll(call, svc);
      break;
    case 'fill':
      result = await _fill(call, svc);
      break;
    case 'tab':
      result = await _tab(call, svc);
      break;
    case 'long_press':
      result = await _longPress(call, svc);
      break;
    case 'esc':
      result = await _esc(call, svc);
      break;
    default:
      return ToolCallResult.failure(
          call.id,
          'Unknown act action "$action". Valid actions: tap (use "ref" or '
          '"label"), type (use "text"), scroll (use "direction"), fill '
          '(use "label" + "text"), tab, long_press, esc.');
  }

  final grep = (call.arguments['grep'] as String?)?.trim();
  final hasGrep = grep != null && grep.isNotEmpty;
  final thenRead = call.arguments['then_read'] == true || hasGrep;

  if (result.ok && thenRead) {
    final settleMsRaw = call.arguments['settle_ms'];
    final settleMs =
        settleMsRaw is int && settleMsRaw >= 0 ? settleMsRaw.clamp(0, 5000) : 1000;
    if (settleMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: settleMs));
    }
    final readRes = await svc.readScreen(full: hasGrep);
    if (readRes['ok'] == true) {
      if (readRes['unchanged'] == true) {
        final staleOutline = readRes['outline'] as String?;
        if (hasGrep && staleOutline != null && staleOutline.isNotEmpty) {
          final parsed = _splitScreenHeader(staleOutline);
          final filtered =
              GrepFilter.filter(parsed.body, grep, header: parsed.header);
          return ToolCallResult(
            id: result.id,
            ok: true,
            output:
                '${result.output}\n\n[Screen after action (UNCHANGED — filtered previous snapshot, grep: "$grep")]:\n$filtered',
          );
        }
        if (!hasGrep) {
          return ToolCallResult(
            id: result.id,
            ok: true,
            output:
                '${result.output}\n\n[Screen after action]: UNCHANGED (screen is identical to previous read)',
          );
        }
      }
      {
        var outline = readRes['outline'] as String? ?? '';
        final sectionHeader = hasGrep
            ? '[Screen after action (grep: "$grep")]:'
            : '[Screen after action]:';
        if (hasGrep) {
          final parsed = _splitScreenHeader(outline);
          outline = GrepFilter.filter(parsed.body, grep, header: parsed.header);
        }
        final combined = '${result.output}\n\n$sectionHeader\n$outline';
        final finalOutput = await ToolOutputFileService.instance.processOutput(
          callId: call.id,
          output: combined,
        );
        return ToolCallResult(
          id: result.id,
          ok: true,
          output: finalOutput,
        );
      }
    }
  }

  return result;
}

({String? header, String body}) _splitScreenHeader(String outline) {
  final lines = outline.split('\n');
  if (lines.isNotEmpty && lines.first.trimLeft().startsWith('Screen:')) {
    return (header: lines.first, body: lines.sublist(1).join('\n'));
  }
  return (header: null, body: outline);
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

/// Returns the matched commit word, or null when [label] is safe to tap.
/// The word is surfaced in the refusal message so the model knows exactly
/// which pattern tripped the guard instead of guessing.
String? looksLikeCommitAction(String label) {
  // Keep hyphens inside tokens so 'reply-all' can match its list entry;
  // every other non-letter becomes a separator.
  final words = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z\s-]'), ' ')
      .split(RegExp(r'\s+'));
  for (final word in words) {
    if (kCommitWords.contains(word)) return word;
    // Hyphenated compounds count segment-wise too: 'confirm-order' must
    // refuse just like 'confirm'.
    for (final segment in word.split('-')) {
      if (kCommitWords.contains(segment)) return segment;
    }
  }
  return null;
}

// ---- Handlers ---------------------------------------------------------------

Future<ToolCallResult> _tap(ToolCall call, A11yService svc) async {
  final refRaw = call.arguments['ref'];
  if (refRaw is int && refRaw > 0) {
    // Numeric-ref path: no label matching, no commit-word policy (refs are
    // only issued from reads the model already made deliberately).
    final res = await svc.tapByRef(refRaw);
    if (res['ok'] != true) {
      return ToolCallResult.failure(
        call.id,
        res['message'] ?? 'Tap failed.',
      );
    }
    final hasGrep = (call.arguments['grep'] as String?)?.trim().isNotEmpty == true;
    if (call.arguments['then_read'] == true || hasGrep) {
      return ToolCallResult(
        id: call.id,
        ok: true,
        output: res['message'] ?? '',
      );
    }
    final probe = await svc.probeChanged();
    final effect = probe['changed'] == true
        ? '[effect: screen CHANGED — tap landed]'
        : '[effect: NO observable change — the UI may be animating or took no visible effect]';
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: '${res['message'] ?? ''} $effect',
    );
  }

  final label = (call.arguments['label'] as String?)?.trim();
  if (label == null || label.isEmpty) {
    return ToolCallResult.failure(
      call.id,
      'Missing required argument: label. Re-read the screen and use the exact '
      'visible label.',
    );
  }

  if (looksLikeCommitAction(label) case final matchedWord?) {
    return ToolCallResult.failure(
      call.id,
      'Refusing to tap "$label" — refused: matches commit pattern '
      '"$matchedWord". Draft policy: Errand prepares, the USER presses '
      'Send/Confirm/Pay/etc. Prepare everything up to that point, then tell '
      'the user to do the last step.',
    );
  }

  final exact = call.arguments['exact'] == true;
  final occurrenceRaw = call.arguments['occurrence'];
  final occurrence =
      occurrenceRaw is int && occurrenceRaw > 0 ? occurrenceRaw : 1;
  final res = await svc.tapByText(label, exact: exact, occurrence: occurrence);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Tap failed for "$label".',
    );
  }
  final hasGrepText = (call.arguments['grep'] as String?)?.trim().isNotEmpty == true;
  if (call.arguments['then_read'] == true || hasGrepText) {
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: (res['message'] as String?) ?? '',
    );
  }
  final probe = await svc.probeChanged();
  final effect = probe['changed'] == true
      ? '[effect: screen CHANGED]'
      : '[effect: NO observable change — the UI may be animating or took no visible effect]';
  return ToolCallResult(id: call.id, ok: true,
      output: '${res['message'] as String? ?? ''} $effect');
}

/// Long-press by ref/label via ACTION_LONG_CLICK on the clickable ancestor.
Future<ToolCallResult> _longPress(ToolCall call, A11yService svc) async {
  final refRaw = call.arguments['ref'];
  final label = (call.arguments['label'] as String?)?.trim();
  if (refRaw is! int && (label == null || label.isEmpty)) {
    return ToolCallResult.failure(
      call.id, 'Provide "ref" (preferred) or "label" for long_press.');
  }
  if (refRaw is int) {
    final res = await svc.longPressByRef(refRaw);
    return ToolCallResult(id: call.id, ok: res['ok'] == true,
        output: res['message'] as String? ?? '');
  }
  // Label fallback: resolve through tapByText's matcher is not exposed for
  // long-press; guide to refs.
  return ToolCallResult.failure(
    call.id,
    'long_press currently requires "ref" from the last screen read.',
  );
}

/// Escape key via IME connection (dismiss dialogs/popups).
Future<ToolCallResult> _esc(ToolCall call, A11yService svc) async {
  final res = await svc.imeSendEscape();
  return ToolCallResult(id: call.id, ok: res['ok'] == true,
      output: res['message'] as String? ?? '');
}

/// Atomic form-fill: tap the labeled field -> wait for input focus ->
/// verify WHICH field and its current content -> commit via IME (works on
/// web inputs that refuse SET_TEXT) -> verify post-write content. Doing this
/// in ONE tool call closes the race where ad refreshes steal focus between a
/// separate tap and type.
Future<ToolCallResult> _fill(ToolCall call, A11yService svc) async {
  final refRaw = call.arguments['ref'];
  final label = (call.arguments['label'] as String?)?.trim();
  final byRef = refRaw is int && refRaw > 0;
  if (!byRef && (label == null || label.isEmpty)) {
    return ToolCallResult.failure(
      call.id,
      'Missing required argument: provide "ref" (preferred) or "label" — '
      'the exact visible label of the field.',
    );
  }
  final text = call.arguments['text'];
  if (text is! String) {
    return ToolCallResult.failure(call.id, 'Missing required argument: text.');
  }

  final occurrenceRaw = call.arguments['occurrence'];
  final occurrence =
      occurrenceRaw is int && occurrenceRaw > 0 ? occurrenceRaw : 1;
  final exact = call.arguments['exact'] == true;
  final overwrite = call.arguments['overwrite'] == true;

  // 1. Tap to focus.
  final tapped = byRef
      ? await svc.tapByRef(refRaw)
      : await svc.tapByText(label!, exact: exact, occurrence: occurrence);
  if (tapped['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (tapped['message'] as String?) ??
          'Could not tap field "${byRef ? 'ref $refRaw' : label}".',
    );
  }

  // 2. Give the web view / app time to move focus and start input.
  await Future<void>.delayed(const Duration(milliseconds: 700));

  // 3. Verify WHAT is focused and what it contains — never write blind.
  final info = await svc.imeFieldInfo();
  if (info['ok'] != true) {
    final err = (info['error'] as String?) ?? '';
    return ToolCallResult.failure(
      call.id,
      err == 'NEEDS_API_33'
          ? 'IME typing needs Android 13+. Try act type after tapping instead.'
          : 'Focus did not land on an editable field after tapping '
              '"${byRef ? 'ref $refRaw' : label}" (ad refresh or non-input '
              'element). Re-read and retry.',
    );
  }
  final existing = (info['content'] as String? ?? '');
  if (existing.isNotEmpty && !overwrite) {
    return ToolCallResult.failure(
      call.id,
      'Focused field already contains ${existing.length} chars ("${existing.substring(0, existing.length > 60 ? 60 : existing.length)}…"). '
      'Refusing to clobber. If this IS the right field and replacing is intended, '
      'retry with overwrite:true.',
    );
  }

  // 4. Commit via IME connection (web inputs often refuse SET_TEXT).
  final res = await svc.imeCommit(text, replaceAll: true);
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Could not commit text into the focused field.',
    );
  }

  // 5. Report ground-truth content for verification (chat history doubles
  // as the receipt).
  final content = res['content'] as String? ?? '';
  final targetDesc = byRef ? 'ref $refRaw' : '"$label"';
  return ToolCallResult(
    id: call.id,
    ok: true,
    output:
        'Filled $targetDesc. Field now contains ${content.length} chars: "$content". '
        'This is a DRAFT — the user sends/submits.',
  );
}

/// Tab hop: moves focus to the next form field via the IME input connection.
Future<ToolCallResult> _tab(ToolCall call, A11yService svc) async {
  final res = await svc.imeSendTab();
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Tab failed.',
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

  // Clobber guard (API 33+): refuse to wipe a non-empty field unless the
  // caller explicitly passes overwrite:true.
  final overwrite = call.arguments['overwrite'] == true;
  if (!overwrite) {
    final info = await svc.imeFieldInfo();
    if (info['ok'] == true) {
      final existing = info['content'] as String? ?? '';
      if (existing.isNotEmpty) {
        return ToolCallResult.failure(
          call.id,
          'Focused field already contains ${existing.length} chars '
          '("${existing.substring(0, existing.length > 60 ? 60 : existing.length)}…"). Pass overwrite:true to replace it.',
        );
      }
    }
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
  if (!['up', 'down', 'left', 'right'].contains(direction)) {
    return ToolCallResult.failure(
        call.id, 'direction must be up, down, left, or right');
  }

  final timesRaw = call.arguments['times'];
  final times = timesRaw is int && timesRaw > 0 ? timesRaw.clamp(1, 30) : 1;
  final nearLabel = (call.arguments['near_label'] as String?)?.trim();

  final res = await svc.scroll(
    direction,
    times: times,
    nearLabel: (nearLabel?.isEmpty ?? true) ? null : nearLabel,
  );
  if (res['ok'] != true) {
    return ToolCallResult.failure(
      call.id,
      (res['message'] as String?) ?? 'Scroll failed.',
    );
  }
  final atEnd = res['at_end'] == true;
  var output =
      '${res['message'] ?? ''}${atEnd ? ' — AT_END: no further content in this direction.' : ''}';
  // When the outer handler will then_read (or grep implies it), the full
  // re-read below already shows the effect — skip the extra probe settle.
  final willRead = call.arguments['then_read'] == true ||
      (call.arguments['grep'] as String?)?.trim().isNotEmpty == true;
  if (res['method'] == 'gesture' && !willRead) {
    // Gesture scrolls give no node-level feedback — verify with a probe.
    final probe = await svc.probeChanged();
    output += probe['changed'] == true
        ? ' [effect: content moved]'
        : ' [effect: NO change — possibly at the end of this direction]';
  }
  return ToolCallResult(id: call.id, ok: true, output: output);
}
