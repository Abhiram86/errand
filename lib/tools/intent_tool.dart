import 'package:flutter/services.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/installed_apps_service.dart';
import 'package:errand/services/intent_service.dart';
import 'package:errand/types/message.dart';
import 'package:errand/types/tool.dart';

Tool intentTool({
  IntentService? service,
  A11yService? a11yService,
  InstalledAppsService? installedAppsService,
}) {
  final svc = service ?? IntentService();
  final a11y = a11yService ?? A11yService();
  final appsSvc = installedAppsService ?? InstalledAppsService.instance;

  return Tool(
    name: 'intent',
    description:
        'Interacts with external Android apps, files, URLs, and settings. '
        'Supports opening local files (images, audio, videos, PDFs), opening URLs or URI schemes '
        '(https, tel, mailto, geo), launching apps by package, navigating system settings pages, '
        'or sending custom intents.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'open_file',
            'open_url',
            'open_app',
            'settings',
            'intent',
          ],
          'description':
              'Action to perform: '
              'open_file (view local audio/image/video/pdf/file on device), '
              'open_url (open web URL, web search, or tel/mailto/geo scheme), '
              'open_app (launch installed app by package name), '
              'settings (open Android settings page), '
              'intent (send custom Android intent).',
        },
        'path': {
          'type': 'string',
          'description':
              'Absolute file path on device for "open_file" (e.g. /storage/emulated/0/Download/song.mp3).',
        },
        'url': {
          'type': 'string',
          'description':
              'URL or URI scheme for "open_url" or "intent" (e.g. https://flutter.dev, tel:+1234567890, '
              'mailto:user@example.com?subject=Hello, geo:0,0?q=London).',
        },
        'package': {
          'type': 'string',
          'description':
              'Android package name for "open_app" (e.g. com.spotify.music, com.android.chrome) or pinning intent.',
        },
        'page': {
          'type': 'string',
          'description':
              'Settings page name for "settings": wifi, bluetooth, display, sound, battery, '
              'apps, storage, location, security, airplane, about, main.',
        },
        'android_action': {
          'type': 'string',
          'description':
              'Raw Android intent action constant for "intent" (e.g. android.settings.DISPLAY_SETTINGS, '
              'android.intent.action.SEND).',
        },
        'type': {
          'type': 'string',
          'description':
              'Optional MIME type (e.g. audio/mpeg, application/pdf). If omitted for open_file, auto-detected from file extension.',
        },
        'extras': {
          'type': 'object',
          'description': 'Optional intent extras as string map for "intent".',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      try {
        return await handleIntentAction(
          call,
          svc,
          a11y: a11y,
          installedAppsService: appsSvc,
        );
      } catch (e) {
        return ToolCallResult.failure(call.id, 'Intent failed: $e');
      }
    },
  );
}

/// Routes an intent [call] through action handlers. Shared by the tool handler
/// and UI replay ([replayIntentAction]).
/// [a11y] is nullable: UI replay passes none (no channel call, no notice).
Future<ToolCallResult> handleIntentAction(
  ToolCall call,
  IntentService svc, {
  A11yService? a11y,
  InstalledAppsService? installedAppsService,
}) async {
  final action = (call.arguments['action'] as String?)?.trim() ?? 'open_url';

  switch (action) {
    case 'open_file':
      return await _openFile(call, svc, a11y);
    case 'open_url':
      return await _openUrl(call, svc, a11y);
    case 'open_app':
      return await _openApp(
        call,
        svc,
        a11y: a11y,
        installedAppsService: installedAppsService,
      );
    case 'settings':
      return await _openSettingsPage(
        call,
        svc,
        (call.arguments['page'] as String?) ??
            (call.arguments['query'] as String?) ??
            'main',
        a11y,
      );
    case 'intent':
      return await _genericIntent(call, svc, a11y);

    // Backward compatibility for persisted chat actions:
    case 'search':
      return await _openUrl(call, svc, a11y);
    case 'dial':
      final query = (call.arguments['query'] as String?)?.trim() ?? '';
      return await _openUrl(
        ToolCall(
          id: call.id,
          name: call.name,
          arguments: {...call.arguments, 'url': 'tel:${Uri.encodeComponent(query)}'},
        ),
        svc,
        a11y,
      );
    case 'open_maps':
      final query = (call.arguments['query'] as String?)?.trim() ?? '';
      return await _openUrl(
        ToolCall(
          id: call.id,
          name: call.name,
          arguments: {...call.arguments, 'url': 'geo:0,0?q=${Uri.encodeQueryComponent(query)}'},
        ),
        svc,
        a11y,
      );
    case 'email':
      final to = (call.arguments['to'] as String?)?.trim() ??
          (call.arguments['query'] as String?)?.trim() ??
          '';
      final subject = (call.arguments['subject'] as String?)?.trim();
      final body = (call.arguments['body'] as String?)?.trim();
      final qp = <String, String>{};
      if (subject != null && subject.isNotEmpty) qp['subject'] = subject;
      if (body != null && body.isNotEmpty) qp['body'] = body;
      final mailtoUri = Uri(
        scheme: 'mailto',
        path: to,
        queryParameters: qp.isEmpty ? null : qp,
      );
      return await _openUrl(
        ToolCall(
          id: call.id,
          name: call.name,
          arguments: {...call.arguments, 'url': mailtoUri.toString()},
        ),
        svc,
        a11y,
      );
    case 'calendar_event':
    case 'media_play':
    case 'share':
    case 'wallpaper':
    case 'uninstall':
    case 'settings_panel':
      return await _genericIntent(call, svc, a11y);

    default:
      return ToolCallResult.failure(
        call.id,
        'Unknown intent action "$action". Valid actions: open_file, open_url, '
        'open_app, settings, intent. (To read the phone SCREEN, use the separate '
        '"screen" tool with action:"read" — not this tool.)',
      );
  }
}

/// Intent actions safe to re-launch from the chat UI without destructive side effects.
const _reopenableActions = {
  'open_file',
  'open_url',
  'open_app',
  'settings',
  // Backward compatibility:
  'search',
  'open_maps',
  'dial',
  'media_play',
  'email',
  'share',
  'wallpaper',
  'settings_panel',
};

/// Android intent actions that merely view or open a surface.
const _viewStyleAndroidActions = {
  'android.intent.action.VIEW',
  'android.intent.action.MAIN',
  'android.intent.action.DIAL',
  'android.intent.action.SENDTO',
  'android.media.action.MEDIA_PLAY_FROM_SEARCH',
};

/// Whether a persisted tool message can be re-launched via the UI's reopen button.
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

/// Re-launches a previously successful intent action from the chat UI ("Reopen" button).
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

bool _looksLikeWebHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.contains(' ')) return false;
  final host = trimmed.split(RegExp(r'[/?#]')).first;
  return host.contains('.');
}

/// Appended to successful open-style intents when screen access is off, so
/// the model knows follow-up screen/act reads will fail. Checked lazily
/// (after a successful launch) so failed launches pay no channel round-trip.
String _pausedNotice(String target) =>
    '\n\n[NOTICE: SCREEN ACCESS PAUSED]\n'
    'The $target was opened, but Errand\'s Screen Access is currently off (it pauses when Errand closes to keep other apps secure). '
    'Because of this, you will not be able to read its screen (screen tool) or interact with it (act tool). '
    'If your task requires reading or controlling $target, inform the user that screen access is off and can be enabled in Settings > Accessibility or via Errand Settings > Tools.';

/// Returns the paused notice when [a11y] is set and the service is off.
/// Null [a11y] (UI replay) or launch failures skip the check entirely.
Future<String> _maybePausedNotice(A11yService? a11y, String target) async {
  if (a11y == null) return '';
  try {
    if (!await a11y.isSupported()) return '';
    if (await a11y.isEnabled()) return '';
  } catch (_) {
    return ''; // channel error: unknown state, don't cry wolf
  }
  return _pausedNotice(target);
}

Future<ToolCallResult> _openSettingsPage(
  ToolCall call,
  IntentService svc,
  String rawPage,
  A11yService? a11y,
) async {
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
    final notice = await _maybePausedNotice(a11y, '$key settings');
    return ToolCallResult(id: call.id, ok: true, output: 'Opened $key settings ($res)$notice');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open $key settings: ${e.message}');
  }
}

Future<ToolCallResult> _openFile(ToolCall call, IntentService svc, A11yService? a11y) async {
  final rawPath = (call.arguments['path'] as String?)?.trim() ??
      (call.arguments['url'] as String?)?.trim() ??
      (call.arguments['query'] as String?)?.trim();

  if (rawPath == null || rawPath.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "path" for open_file');
  }

  // Gracefully handle if model passed an HTTP/HTTPS URL to open_file
  if (rawPath.startsWith('http://') || rawPath.startsWith('https://')) {
    return await _openUrl(call, svc, a11y);
  }

  final pkg = call.arguments['package'] as String?;
  final type = call.arguments['type'] as String?;
  final extras = _parseStringMap(call.arguments['extras']);

  try {
    final res = await svc.launchAction(
      'open_file',
      data: rawPath,
      package: pkg,
      type: type,
      extras: extras,
    );
    final notice = await _maybePausedNotice(a11y, 'file $rawPath');
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: 'Opened file: $rawPath ($res)$notice',
    );
  } on PlatformException catch (e) {
    return ToolCallResult.failure(
      call.id,
      'Failed to open file "$rawPath": ${e.message}',
    );
  }
}

Future<ToolCallResult> _openUrl(ToolCall call, IntentService svc, A11yService? a11y) async {
  final rawUrl = (call.arguments['url'] as String?)?.trim() ??
      (call.arguments['path'] as String?)?.trim();

  if (rawUrl == null || rawUrl.isEmpty) {
    // If query was passed (e.g. web search), construct Google search URL
    final query = (call.arguments['query'] as String?)?.trim();
    if (query != null && query.isNotEmpty) {
      final searchUrl =
          'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}';
      final pkg = call.arguments['package'] as String?;
      try {
        final res =
            await svc.launchAction('open_url', data: searchUrl, package: pkg);
        final notice = await _maybePausedNotice(a11y, 'web search for "$query"');
        return ToolCallResult(
            id: call.id, ok: true, output: 'Searched web for "$query": $res$notice');
      } on PlatformException catch (e) {
        return ToolCallResult.failure(
            call.id, 'Web search failed: ${e.message}');
      }
    }
    return ToolCallResult.failure(call.id, 'Missing "url" for open_url');
  }

  // Auto-route local files to open_file
  if (rawUrl.startsWith('/') || rawUrl.startsWith('file://')) {
    return await _openFile(call, svc, a11y);
  }

  final uri = Uri.tryParse(rawUrl);
  final hasScheme = uri != null && uri.hasScheme;

  if (!hasScheme && !_looksLikeWebHost(rawUrl)) {
    return ToolCallResult.failure(
      call.id,
      '"$rawUrl" is not a valid URL or scheme. Use https://..., tel:..., mailto:..., geo:..., '
      'action:"open_file" for local files, or action:"settings" for settings.',
    );
  }

  String url = rawUrl;
  if (!hasScheme) {
    url = 'https://$rawUrl';
  } else {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'javascript') {
      return ToolCallResult.failure(
          call.id, 'Blocked unsafe URL scheme: "$scheme"');
    }
  }

  final pkg = call.arguments['package'] as String?;
  final extras = _parseStringMap(call.arguments['extras']);

  try {
    final res = await svc.launchAction(
      'open_url',
      data: url,
      package: pkg,
      extras: extras,
    );
    final notice = await _maybePausedNotice(a11y, 'URL $url');
    return ToolCallResult(
        id: call.id, ok: true, output: 'Opened URL: $url ($res)$notice');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed to open URL: ${e.message}');
  }
}

Future<ToolCallResult> _openApp(
  ToolCall call,
  IntentService svc, {
  A11yService? a11y,
  InstalledAppsService? installedAppsService,
}) async {
  final rawPkg = (call.arguments['package'] as String?)?.trim();
  if (rawPkg == null || rawPkg.isEmpty) {
    return ToolCallResult.failure(call.id, 'Missing "package" for open_app');
  }

  final appsSvc = installedAppsService ?? InstalledAppsService.instance;
  // If the model passed an app label or alias (e.g. 'BookMyShow' or 'yt music'), resolve it.
  final exact = appsSvc.findExact(rawPkg);
  final pkgToLaunch = exact?.package ?? rawPkg;

  try {
    final res = await svc.launchAction('open_app', package: pkgToLaunch);
    final appLabel = appsSvc.getLabel(pkgToLaunch);
    final notice = await _maybePausedNotice(a11y, 'app $appLabel');
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: 'Launched app: $appLabel ($pkgToLaunch - $res)$notice',
    );
  } catch (e) {
    final matches = appsSvc.findBestMatches(rawPkg, limit: 10);
    if (matches.isNotEmpty) {
      final suggestions =
          matches.map((a) => '- ${a.label} (${a.package})').join('\n');
      return ToolCallResult.failure(
        call.id,
        'Failed to launch app "$rawPkg": package not found or cannot be launched.\n'
        'Top matching installed apps on this device:\n$suggestions\n\n'
        'Please retry open_app using one of the exact package names above.',
      );
    }
    final message = e is PlatformException ? (e.message ?? e.code) : '$e';
    return ToolCallResult.failure(
      call.id,
      'Failed to launch app "$rawPkg": $message',
    );
  }
}

const _androidActions = <String, String>{
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

Future<ToolCallResult> _genericIntent(ToolCall call, IntentService svc, A11yService? a11y) async {
  final action = call.arguments['action'] as String;
  final pkg = call.arguments['package'] as String?;
  final extras = _parseStringMap(call.arguments['extras']) ?? {};
  final type = call.arguments['type'] as String?;
  final query = (call.arguments['query'] as String?)?.trim();
  final url = (call.arguments['url'] as String?)?.trim() ??
      (call.arguments['path'] as String?)?.trim();
  final rawAction = (call.arguments['android_action'] as String?)?.trim();

  String? androidAction = rawAction ?? _androidActions[action];
  String? mimeOverride;
  String? targetPackage = pkg;
  String? data = url;

  if (action == 'settings_panel') {
    final panel = call.arguments['panel'] as String? ?? 'internet';
    androidAction = _panelActions[panel];
    if (androidAction == null) {
      return ToolCallResult.failure(
        call.id,
        'Unknown panel "$panel". Valid panels: ${_panelActions.keys.join(", ")}',
      );
    }
  } else if (action == 'calendar_event') {
    if (query == null || query.isEmpty) {
      return ToolCallResult.failure(
          call.id, 'Provide "query" as event title for calendar_event');
    }
    extras['title'] = query;
    data = 'content://com.android.calendar/events';
  } else if (action == 'media_play') {
    if (query == null || query.isEmpty) {
      return ToolCallResult.failure(
          call.id, 'Provide "query" e.g. artist/song for media_play');
    }
    extras['query'] = query;
  } else if (action == 'share') {
    final text = query ??
        call.arguments['body'] as String? ??
        call.arguments['url'] as String?;
    if (text == null || text.isEmpty) {
      return ToolCallResult.failure(
          call.id, 'Provide "query" (or body/url) text to share');
    }
    extras['android.intent.extra.TEXT'] = text;
    if (type == null || type.isEmpty) {
      mimeOverride = 'text/plain';
    }
  } else if (action == 'uninstall') {
    if (pkg == null || pkg.isEmpty) {
      return ToolCallResult.failure(
          call.id, 'Provide "package" to uninstall, e.g. com.example.app');
    }
    data = 'package:$pkg';
    targetPackage = null;
  } else if (action == 'intent') {
    if ((data == null || data.isEmpty) && (androidAction == null || androidAction.isEmpty)) {
      return ToolCallResult.failure(
        call.id,
        'Provide "url" (data Uri) or "android_action" (raw intent action) for generic intent',
      );
    }
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
    final notice = await _maybePausedNotice(a11y, '$action intent');
    return ToolCallResult(
        id: call.id, ok: true, output: 'Sent $action intent ($res)$notice');
  } on PlatformException catch (e) {
    return ToolCallResult.failure(call.id, 'Failed $action intent: ${e.message}');
  }
}
