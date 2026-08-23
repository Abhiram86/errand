import 'package:flutter/services.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/intent_service.dart';
import 'package:errand/types/message.dart';
import 'package:errand/types/tool.dart';

Tool intentTool({IntentService? service}) {
  final svc = service ?? IntentService();

  return Tool(
    name: 'intent',
    description:
        'Opens apps/URLs/web search/dialer/email or toggles system settings on Android. '
        'Use open_url for https or deeplinks, search for web searches, '
        'email for composing emails (to, subject, body), open_app for packages, '
        'open_maps for location search, dial for phone numbers, '
        'and system to toggle Dark Mode.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'open_url',
            'search',
            'open_app',
            'open_maps',
            'dial',
            'email',
            'alarm',
            'timer',
            'calendar_event',
            'media_play',
            'share',
            'wallpaper',
            'uninstall',
            'settings_panel',
            'settings',
            'system',
            'intent'
          ],
          'description':
              'Action to perform. search=web search, open_url=URLs/deeplinks, '
              'email=compose mail, alarm/timer=set alarm or countdown (use query like "07:30" or minutes), '
              'calendar_event=create event, media_play=play music query, share=share text via sheet, '
              'wallpaper=open wallpaper picker, uninstall=prompt app removal, '
              'settings_panel=slide-over wifi/internet/volume panel, '
              'settings=open a system settings page (use "page").',
        },
        'url': {
          'type': 'string',
          'description':
              'URL/deeplink for open_url/intent (e.g. https://flutter.dev, spotify:track/xxx)',
        },
        'query': {
          'type': 'string',
          'description':
              'Search query for "search"/"media_play", location for open_maps, phone number for dial, '
              'time for alarm ("07:30") / timer ("10" minutes), event title for calendar_event, text for share',
        },
        'to': {
          'type': 'string',
          'description': 'Recipient email address for "email" (e.g. alex@example.com)',
        },
        'subject': {
          'type': 'string',
          'description': 'Email subject line for "email"',
        },
        'body': {
          'type': 'string',
          'description': 'Email body content for "email"',
        },
        'android_action': {
          'type': 'string',
          'description':
              'Raw Android intent action for action:"intent" (e.g. android.settings.DISPLAY_SETTINGS, '
              'android.settings.WIFI_SETTINGS, com.someapp.action.SYNC). Use this when no curated action fits.',
        },
        'package': {
          'type': 'string',
          'description':
              'Explicit Android package e.g. com.spotify.music, com.google.android.apps.maps, com.android.chrome. Required for open_app/uninstall.',
        },
        'panel': {
          'type': 'string',
          'enum': ['internet', 'wifi', 'volume', 'nfc'],
          'description': 'Which settings panel to slide over, for settings_panel action.',
        },
        'page': {
          'type': 'string',
          'description':
              'Settings page for "settings" action: main, display, dark_theme, sound, wifi, '
              'bluetooth, battery, apps, storage, location, security, airplane, about',
        },
        'setting': {
          'type': 'string',
          'enum': ['dark_mode'],
          'description': 'System setting to toggle. Currently supports dark_mode.',
        },
        'value': {
          'type': 'integer',
          'description': '0 = OFF/Light, 1 = ON/Dark (for dark_mode)',
        },
        'extras': {
          'type': 'object',
          'description': 'Optional intent extras as string map',
        },
        'type': {
          'type': 'string',
          'description': 'MIME type for SEND intents',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      try {
        return await handleIntentAction(call, svc);
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Intent failed: $e');
      }
    },
  );
}

/// Routes one intent [call] through the curated-action switch. Shared by
/// the tool handler and UI replay ([replayIntentAction]) so reopen gets
/// identical URL-safety, extras parsing and error mapping.
Future<ToolCallResult> handleIntentAction(
  ToolCall call,
  IntentService svc,
) async {
  final action = call.arguments['action'] as String;

  switch (action) {
    case 'open_url':
      return await _openUrl(call, svc);
    case 'search':
      return await _search(call, svc);
    case 'open_app':
      return await _openApp(call, svc);
    case 'open_maps':
      return await _openMaps(call, svc);
    case 'dial':
      return await _dial(call, svc);
    case 'email':
      return await _email(call, svc);
    case 'alarm':
    case 'timer':
    case 'calendar_event':
    case 'media_play':
    case 'share':
    case 'wallpaper':
    case 'uninstall':
    case 'settings_panel':
    case 'intent':
      return await _genericIntent(call, svc);
    case 'settings':
      return await _openSettingsPage(
        call,
        svc,
        (call.arguments['page'] as String?) ??
            (call.arguments['query'] as String?) ??
            'main',
      );
    case 'system':
      return await _systemAction(call, svc);
    default:
      return ToolCallResult.failure(
          call.id,
          'Unknown intent action "$action". Valid actions: open_url, search, '
          'open_app, open_maps, dial, email, alarm, timer, calendar_event, '
          'media_play, share, wallpaper, uninstall, settings_panel, settings, '
          'system, intent. (To read the phone SCREEN, use the separate '
          '"screen" tool with action:"read" — not this tool.)');
  }
}

/// Intent actions that are safe to re-launch from the chat UI: everything
/// that merely OPENS a surface (URL, app, page, panel, composer, sheet)
/// can be re-tapped freely. Excludes only actions with side effects:
/// alarm/timer/calendar_event (re-tap creates duplicates), system (toggles
/// state), uninstall (destructive prompt).
const _reopenableActions = {
  'open_url',
  'open_app',
  'open_maps',
  'search',
  'dial',
  'media_play',
  'email',
  'share',
  'wallpaper',
  'settings',
  'settings_panel',
};

/// Android intent actions that merely OPEN a surface (no side effects), so
/// a raw `intent` call resolving to one of these is as safe to re-tap as
/// open_url. Anything not listed — third-party custom actions especially —
/// has unknown semantics and stays button-less.
const _viewStyleAndroidActions = {
  'android.intent.action.VIEW', // open content (files, URIs, deeplinks)
  'android.intent.action.MAIN', // launcher-style app open
  'android.intent.action.DIAL', // pre-fills the dialler, never dials
  'android.intent.action.SENDTO', // opens a composer/picker, sends nothing
  'android.media.action.MEDIA_PLAY_FROM_SEARCH',
};

/// Whether a persisted tool message can be re-launched via the UI's
/// reopen button: an intent tool success whose launch was open-style.
///
/// The rule is about WHAT was launched, not which tool path produced it:
/// curated open-style actions always qualify; a raw `intent` qualifies only
/// when it resolved to a view-style Android action (or a bare data Uri,
/// which defaults to ACTION_VIEW) or an android.settings.* page.
///
/// Derives everything from already-persisted data (tool name + args +
/// result text), so it works for conversations stored before this
/// feature existed — no schema change.
bool isReopenable(ToolMessage message) {
  if (message.tool.name != 'intent') return false;
  if (message.result.startsWith('ERROR')) return false;

  final action = message.tool.args['action'];
  if (_reopenableActions.contains(action)) return true;

  if (action == 'intent') {
    final androidAction =
        (message.tool.args['android_action'] as String?)?.trim();
    if (androidAction == null || androidAction.isEmpty) return true;
    return _viewStyleAndroidActions.contains(androidAction) ||
        androidAction.startsWith('android.settings.');
  }
  return false;
}

/// Re-launches a previously successful intent action from the chat UI
/// ("Reopen" button). Returns the human-readable outcome; never throws —
/// every failure (bad persisted args, MissingPluginException, …) comes
/// back as "ERROR: ..." text so the button's SnackBar path handles it.
Future<String> replayIntentAction(Map<String, dynamic> args) async {
  try {
    final call = ToolCall(
      id: 'reopen-${DateTime.now().millisecondsSinceEpoch}',
      name: 'intent',
      arguments: args,
    );
    final result = await handleIntentAction(call, IntentService());
    return result.toText();
  } catch (e) {
    return 'ERROR: $e';
  }
}

// --- Safe map parser ---
Map<String, String>? _parseStringMap(dynamic raw) {
  if (raw is! Map) return null;
  final result = <String, String>{};
  raw.forEach((key, val) {
    if (key != null && val != null) {
      result[key.toString()] = val.toString();
    }
  });
  return result.isEmpty ? null : result;
}

/// Common Android settings pages -> intent actions.
const _settingsPages = <String, String>{
  'settings': 'android.settings.SETTINGS',
  'main': 'android.settings.SETTINGS',
  'display': 'android.settings.DISPLAY_SETTINGS',
  'dark_theme': 'android.settings.DARK_THEME_SETTINGS',
  'dark_mode': 'android.settings.DARK_THEME_SETTINGS',
  'sound': 'android.settings.SOUND_SETTINGS',
  'volume': 'android.settings.SOUND_SETTINGS',
  'wifi': 'android.settings.WIFI_SETTINGS',
  'bluetooth': 'android.settings.BLUETOOTH_SETTINGS',
  'battery': 'android.settings.BATTERY_SAVER_SETTINGS',
  'apps': 'android.settings.APPLICATION_SETTINGS',
  'storage': 'android.settings.INTERNAL_STORAGE_SETTINGS',
  'location': 'android.settings.LOCATION_SOURCE_SETTINGS',
  'security': 'android.settings.SECURITY_SETTINGS',
  'airplane': 'android.settings.AIRPLANE_MODE_SETTINGS',
  'about': 'android.settings.DEVICE_INFO',
  'device_info': 'android.settings.DEVICE_INFO',
};

/// True when a scheme-less string is plausibly a web host
/// (e.g. "flutter.dev", "www.example.com/path?q=1").
bool _looksLikeWebHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.contains(' ')) return false;
  final host = trimmed.split(RegExp(r'[/?#]')).first;
  return host.contains('.');
}

Future<ToolCallResult> _openSettingsPage(
    ToolCall call, IntentService svc, String rawPage) async {
  var key = rawPage.trim().toLowerCase().replaceAll('android.settings.', '');
  if (key.endsWith('_settings')) {
    key = key.substring(0, key.length - '_settings'.length);
  }
  final androidAction = _settingsPages[key];
  if (androidAction == null) {
    return ToolCallResult.failure(
      call.id,
      'Unknown settings page "$rawPage". Valid pages: ${_settingsPages.keys.toSet().join(", ")}',
    );
  }
  try {
    final res = await svc.launchAction('intent', androidAction: androidAction);
    return ToolCallResult(id: call.id, ok: true, output: 'Opened $key settings ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open $key settings: ${e.message}');
  }
}

// --- individual action handlers ---

Future<ToolCallResult> _openUrl(ToolCall call, IntentService svc) async {
  final rawUrl = (call.arguments['url'] as String?)?.trim();
  if (rawUrl == null || rawUrl.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "url" for open_url');
  }

  final uri = Uri.tryParse(rawUrl);
  final hasScheme = uri != null && uri.hasScheme;

  // Only auto-prefix plausible web hosts. Anything else without a scheme
  // (settings names, action strings, bare words) is not a URL — fail with
  // guidance instead of inventing "https://...".
  if (!hasScheme && !_looksLikeWebHost(rawUrl)) {
    return ToolCallResult.failure(
      call.id,
      '"$rawUrl" is not a URL. For Android system/app actions use '
      'action:"intent" with "android_action" (e.g. android.settings.DISPLAY_SETTINGS), '
      'or action:"settings" with "page".',
    );
  }

  // Normalize URL schema
  String url = rawUrl;
  if (!hasScheme) {
    url = 'https://$rawUrl';
  } else {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'javascript' || scheme == 'file') {
      return ToolCallResult.failure(
          call.id, 'Blocked unsafe URL scheme: "$scheme"');
    }
  }

  final pkg = call.arguments['package'] as String?;
  final extras = _parseStringMap(call.arguments['extras']);

  try {
    final res = await svc.launchAction('open_url', data: url, package: pkg, extras: extras);
    return ToolCallResult(id: call.id, ok: true, output: 'Opened URL: $url ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open URL: ${e.message}');
  }
}

Future<ToolCallResult> _search(ToolCall call, IntentService svc) async {
  final query = (call.arguments['query'] as String?)?.trim() ??
      (call.arguments['url'] as String?)?.trim();

  if (query == null || query.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "query" for search action');
  }

  final searchUrl = 'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}';
  final pkg = call.arguments['package'] as String?;

  try {
    final res = await svc.launchAction('open_url', data: searchUrl, package: pkg);
    return ToolCallResult(
        id: call.id, ok: true, output: 'Searched web for "$query": $res');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Web search failed: ${e.message}');
  }
}

Future<ToolCallResult> _openApp(ToolCall call, IntentService svc) async {
  final pkg = call.arguments['package'] as String?;
  if (pkg == null || pkg.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "package" for open_app');
  }
  try {
    final res = await svc.launchAction('open_app', package: pkg);
    return ToolCallResult(id: call.id, ok: true, output: 'Launched app: $pkg ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to launch app "$pkg": ${e.message}');
  }
}

Future<ToolCallResult> _openMaps(ToolCall call, IntentService svc) async {
  final query = call.arguments['query'] as String?;
  final pkg = call.arguments['package'] as String?;
  if (query == null || query.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "query" for open_maps');
  }
  final encoded = Uri.encodeQueryComponent(query);
  final data = 'geo:0,0?q=$encoded';
  try {
    final res = await svc.launchAction('open_maps', data: data, package: pkg);
    return ToolCallResult(id: call.id, ok: true, output: 'Opened maps for: $query ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open maps: ${e.message}');
  }
}

Future<ToolCallResult> _dial(ToolCall call, IntentService svc) async {
  final query = call.arguments['query'] as String?;
  if (query == null || query.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "query" for dial');
  }
  final data = 'tel:${Uri.encodeComponent(query)}';
  try {
    final res = await svc.launchAction('dial', data: data);
    return ToolCallResult(id: call.id, ok: true, output: 'Dialling: $query ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to dial number: ${e.message}');
  }
}

Future<ToolCallResult> _email(ToolCall call, IntentService svc) async {
  final extrasMap = _parseStringMap(call.arguments['extras']);

  final to = (call.arguments['to'] as String?)?.trim() ??
      (call.arguments['query'] as String?)?.trim();
  final subject = (call.arguments['subject'] as String?)?.trim() ??
      extrasMap?['subject'];
  final body = (call.arguments['body'] as String?)?.trim() ??
      extrasMap?['body'];
  final type = call.arguments['type'] as String?;

  final queryParams = <String, String>{};
  if (subject != null && subject.isNotEmpty) queryParams['subject'] = subject;
  if (body != null && body.isNotEmpty) queryParams['body'] = body;

  final mailtoUri = Uri(
    scheme: 'mailto',
    path: to ?? '',
    queryParameters: queryParams.isEmpty ? null : queryParams,
  );

  final extras = <String, String>{};
  if (subject != null && subject.isNotEmpty) extras['subject'] = subject;
  if (body != null && body.isNotEmpty) extras['body'] = body;

  try {
    final res = await svc.launchAction(
      'email',
      data: mailtoUri.toString(),
      type: type,
      extras: extras,
    );
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: 'Opened email composer: ${to ?? "blank recipient"} ($res)',
    );
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open email composer: ${e.message}');
  }
}

/// Maps curated tool actions to Android intent action constants.
const _androidActions = <String, String>{
  'alarm': 'android.intent.action.SET_ALARM',
  'timer': 'android.intent.action.SET_TIMER',
  'calendar_event': 'android.intent.action.INSERT',
  'media_play': 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
  'share': 'android.intent.action.SEND',
  'wallpaper': 'android.intent.action.SET_WALLPAPER',
  'uninstall': 'android.intent.action.DELETE',
  'settings_panel': 'android.settings.panel.action.INTERNET_CONNECTIVITY',
};

const _panelActions = <String, String>{
  'internet': 'android.settings.panel.action.INTERNET_CONNECTIVITY',
  'wifi': 'android.settings.panel.action.WIFI',
  'volume': 'android.settings.panel.action.VOLUME',
  'nfc': 'android.settings.panel.action.NFC',
};

Future<ToolCallResult> _genericIntent(ToolCall call, IntentService svc) async {
  final action = call.arguments['action'] as String;
  final pkg = call.arguments['package'] as String?;
  final extras = _parseStringMap(call.arguments['extras']) ?? {};
  final type = call.arguments['type'] as String?;
  final query = (call.arguments['query'] as String?)?.trim();

  // Resolve the concrete Android action for curated actions.
  String? androidAction = _androidActions[action];
  if (action == 'settings_panel') {
    final panel = call.arguments['panel'] as String? ?? 'internet';
    androidAction = _panelActions[panel];
    if (androidAction == null) {
      return ToolCallResult.failure(
        call.id,
        'Unknown panel "$panel". Valid panels: ${_panelActions.keys.join(", ")}',
      );
    }
  }
  String? mimeOverride;
  String? targetPackage = pkg;

  // Per-action argument validation + extra building.
  String? data;
  switch (action) {
    case 'alarm':
      {
        // query like "07:30" or "7.30"; extras allow hour/minutes override.
        final match = _alarmTimeRe.firstMatch(query ?? '');
        if (match != null && !extras.containsKey('android.intent.extra.alarm.HOUR')) {
          final hour = int.parse(match.group(1)!);
          final minutes = int.parse(match.group(2)!);
          if (hour > 23 || minutes > 59) {
            return ToolCallResult.failure(
                call.id, 'Invalid alarm time "$query" — use HH:mm (00-23:00-59)');
          }
          extras['android.intent.extra.alarm.HOUR'] = hour.toString();
          extras['android.intent.extra.alarm.MINUTES'] = minutes.toString();
        }
        if (extras.isEmpty) {
          return ToolCallResult.failure(
              call.id, 'Provide "query" as HH:mm or extras hour/minutes for alarm');
        }
        extras['android.intent.extra.alarm.SKIP_UI'] = 'false';
      }
    case 'timer':
      {
        final minutes = int.tryParse(query ?? '');
        if (minutes == null || minutes <= 0) {
          return ToolCallResult.failure(
              call.id, 'Provide "query" as timer length in minutes, e.g. "10"');
        }
        extras['android.intent.extra.alarm.LENGTH'] = (minutes * 60).toString();
        extras['android.intent.extra.alarm.SKIP_UI'] = 'true';
      }
    case 'calendar_event':
      {
        if (query == null || query.isEmpty) {
          return ToolCallResult.failure(
              call.id, 'Provide "query" as event title for calendar_event');
        }
        extras['title'] = query;
        // CalendarContract.Events.CONTENT_URI — ACTION_INSERT expects the
        // events table; /time is the time-reference URI and calendar apps
        // will open a day view instead of pre-filling a new event.
        data = 'content://com.android.calendar/events';
      }
    case 'media_play':
      {
        if (query == null || query.isEmpty) {
          return ToolCallResult.failure(
              call.id, 'Provide "query" e.g. artist/song for media_play');
        }
        extras['query'] = query;
      }
    case 'share':
      {
        final text = query ??
            call.arguments['body'] as String? ??
            call.arguments['url'] as String?;
        if (text == null || text.isEmpty) {
          return ToolCallResult.failure(
              call.id, 'Provide "query" (or body/url) text to share');
        }
        extras['android.intent.extra.TEXT'] = text;
        // ACTION_SEND requires a MIME type — default instead of failing.
        if (type == null || type.isEmpty) {
          mimeOverride = 'text/plain';
        }
      }
    case 'uninstall':
      {
        if (pkg == null || pkg.isEmpty) {
          return ToolCallResult.failure(
              call.id, 'Provide "package" to uninstall, e.g. com.example.app');
        }
        data = 'package:$pkg';
        // The uninstaller lives in com.android.packageinstaller — do NOT pin
        // the target package on the intent or resolution will fail.
        targetPackage = null;
      }
    case 'intent':
      {
        final url = call.arguments['url'] as String?;
        final rawAction = call.arguments['android_action'] as String?;
        if ((url == null || url.isEmpty) && (rawAction == null || rawAction.isEmpty)) {
          return ToolCallResult.failure(
              call.id,
              'Provide "url" (data Uri) or "android_action" (raw intent action) for generic intent');
        }
        if (rawAction != null && rawAction.isNotEmpty) {
          androidAction = rawAction;
        }
        data = url;
      }
    // wallpaper / settings_panel need no data or extras.
  }

  try {
    final res = await svc.launchAction(
      'intent',
      androidAction: androidAction,
      data: data,
      package: targetPackage,
      extras: extras.isEmpty ? null : extras,
      type: mimeOverride ?? type,
    );
    return ToolCallResult(
        id: call.id, ok: true, output: 'Sent $action intent ($res)');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed $action intent: ${e.message}');
  }
}

// --- System toggle handler ---
final _alarmTimeRe = RegExp(r'^(\d{1,2})[:.](\d{2})$');

Future<ToolCallResult> _systemAction(ToolCall call, IntentService svc) async {
  final setting = call.arguments['setting'] as String?;
  // LLM JSON may decode integers as doubles (1.0) — coerce instead of casting.
  final value = (call.arguments['value'] as num?)?.toInt() ?? 0;

  if (setting == null || setting.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "setting" for system action');
  }

  try {
    final result = await svc.toggleSystemSetting(setting, value);
    return ToolCallResult(id: call.id, ok: true, output: result);
  } on PlatformException catch (e) {
    if (e.code == 'PERMISSION_MISSING') {
      // Respect already-granted state — don't re-open settings if toggle is ON.
      final alreadyGranted = await svc.hasWriteSettings();
      if (alreadyGranted) {
        // Permission shows ON but toggle still threw PERMISSION_MISSING (stale).
        // Tell model to retry once; next call will hit UiModeManager path without permission.
        return ToolCallResult.failure(
            call.id,
            'System reported permission already granted but toggle still needs it. '
            'Retrying dark_mode toggle once — if it persists, the system blocks programmatic toggle and you should open Display settings.');
      }
      final wasAlreadyGranted = await svc.requestWriteSettings();
      if (wasAlreadyGranted) {
        // Race: permission was actually granted between check and request.
        try {
          final retry = await svc.toggleSystemSetting(setting, value);
          return ToolCallResult(id: call.id, ok: true, output: retry);
        } catch (_) {
          // fall through to message
        }
      }
      return ToolCallResult.failure(
          call.id,
          'WRITE_SETTINGS permission required. '
          'I opened the system dialog for you—please toggle "Allow modify system settings" ON for Errand and try again. '
          'Note: dark_mode now also tries UiModeManager first, so a retry often succeeds without permission.');
    }
    if (e.code == 'PERMISSION_DENIED') {
      return ToolCallResult.failure(
          call.id, 'System toggle blocked by OS (WRITE_SECURE_SETTINGS required). ${e.message} — opened Display settings for manual toggle.');
    }
    return ToolCallResult.failure(call.id, 'System toggle failed: ${e.message}');
  } catch (e) {
    return ToolCallResult.failure(call.id, 'System toggle failed: $e');
  }
}