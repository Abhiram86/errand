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
  bool isHeadless = false,
}) {
  final svc = service ?? IntentService();
  final a11y = a11yService ?? A11yService();
  final appsSvc = installedAppsService ?? InstalledAppsService.instance;

  return Tool(
    name: 'intent',
    description: isHeadless
        ? 'Interacts with external Android system services and intents in background headless mode. '
            'Non-UI background intents (alarms, timers, calendar entries, system broadcasts) and docs are supported. '
            'Interactive UI actions (open_app, settings, open_file, open_url) are disabled in background mode.'
        : 'Interacts with external Android apps, files, URLs, settings, and Android intents. '
            'Supports opening local files (images, audio, videos, PDFs), opening URLs or URI schemes '
            '(https, tel, mailto, geo), launching apps by package, navigating system settings pages, '
            'or sending a custom Android intent. For action:"intent", pass the exact Android '
            'action constant, data URI, MIME type, package, and typed extras required by the target app. '
            'Errand does not infer or synthesize app-specific fields.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['open_file', 'open_url', 'open_app', 'settings', 'intent', 'docs'],
          'description':
              'Action to perform: '
              'open_file (view local audio/image/video/pdf/file on device), '
              'open_url (open web URL, web search, or tel/mailto/geo scheme in external handler; for websites you need to read or interact with use "browser"), '
              'open_app (launch installed app by package name; for web services with browser access use "browser"), '
              'settings (open Android settings page), '
              'intent (send a custom Android intent; provide exact target fields), '
              'docs (look up expected Android intent action, extras, types, and schema by intent name).',
        },
        'name': {
          'type': 'string',
          'description':
              'Name/topic of the intent to look up definition, expected extras, and types for (used with action:"docs", e.g. "timer", "calendar", "audio").',
        },
        'path': {
          'type': 'string',
          'description': 'Absolute file path on device for "open_file" (e.g. /storage/emulated/0/Download/song.mp3).',
        },
        'url': {
          'type': 'string',
          'description':
              'URL or URI scheme for "open_url" or "intent" (e.g. https://flutter.dev, tel:+1234567890, '
              'mailto:user@example.com?subject=Hello, geo:0,0?q=London).',
        },
        'package': {
          'type': 'string',
          'description': 'Android package name for "open_app" (e.g. com.spotify.music, com.android.chrome) or pinning intent.',
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
              'Exact Android intent action constant for "intent" (e.g. '
              'android.settings.DISPLAY_SETTINGS, android.intent.action.SET_ALARM, '
              'android.intent.action.INSERT). Use the exact target contract; do not shorten '
              'extra keys. Alarm uses android.intent.extra.alarm.HOUR and '
              'android.intent.extra.alarm.MINUTES (plural). Calendar insertion uses '
              'content://com.android.calendar/events.',
        },
        'type': {
          'type': 'string',
          'description': 'Optional MIME type (e.g. audio/mpeg, application/pdf). If omitted for open_file, auto-detected from file extension.',
        },
        'extras': {
          'type': 'object',
          'description':
              'Optional typed Android extras for "intent". Keys and value types must match the '
              'target app contract. Values may be strings, booleans, integers, numbers, or arrays '
              'of strings. For example, calendar timestamps are milliseconds since epoch and '
              'allDay is a boolean; alarm keys use the android.intent.extra.alarm.* names. '
              'No aliases are generated.',
        },
      },
      'required': ['action'],
    },
    handler: (call) async {
      final action = (call.arguments['action'] as String?)?.trim().toLowerCase();
      if (isHeadless) {
        if (action == 'open_app' ||
            action == 'settings' ||
            action == 'open_file' ||
            action == 'open_url') {
          return ToolCallResult.failure(
            call.id,
            'Action "$action" opens interactive foreground UI and is disabled in background scheduled tasks.',
            type: 'headless_ui_intent_blocked',
          );
        }
        if (action == 'intent') {
          final androidAction =
              (call.arguments['android_action'] as String?)?.trim() ?? '';
          if (androidAction.startsWith('android.settings.') ||
              androidAction == 'android.intent.action.VIEW' ||
              androidAction == 'android.intent.action.MAIN') {
            return ToolCallResult.failure(
              call.id,
              'Android intent action "$androidAction" opens an interactive UI window and is blocked in background scheduled tasks.',
              type: 'headless_ui_intent_blocked',
            );
          }
        }
      }
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
    case 'docs':
      return _intentDocs(call);
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

    // Backward compatibility for URI-style actions that are equivalent to
    // open_url. Custom Android actions must use action:"intent" explicitly.
    case 'search':
      return await _openUrl(call, svc, a11y);
    case 'dial':
      final query = (call.arguments['query'] as String?)?.trim() ?? '';
      return await _openUrl(
        ToolCall(
          id: call.id,
          name: call.name,
          arguments: {
            ...call.arguments,
            'url': 'tel:${Uri.encodeComponent(query)}',
          },
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
          arguments: {
            ...call.arguments,
            'url': 'geo:0,0?q=${Uri.encodeQueryComponent(query)}',
          },
        ),
        svc,
        a11y,
      );
    case 'email':
      final to =
          (call.arguments['to'] as String?)?.trim() ??
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
  'email',
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
    final androidAction = (message.tool.args['android_action'] as String?)
        ?.trim();
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

/// Default verified definitions and schemas for action: "docs".
const Map<String, String> kDefaultIntentDocs = {
  'alarm': '''### Android Alarm & Timer Intent Specification (`android.provider.AlarmClock`)

1. CREATE / SCHEDULE ALARM:
- action: "intent"
- android_action: "android.intent.action.SET_ALARM"
- Behavior: Directly schedules an alarm in the default Clock app. If "android.intent.extra.alarm.SKIP_UI" is true, it is set silently in the background and confirms via system toast. If false or omitted, it opens the Clock app at the alarm creation screen.
- Eligible Extras:
  * "android.intent.extra.alarm.HOUR" (int, required): Hour of the alarm in 24-hour format (0-23). E.g. 7 for 7 AM, 19 for 7 PM.
  * "android.intent.extra.alarm.MINUTES" (int, required): Minute of the hour (0-59). E.g. 30.
  * "android.intent.extra.alarm.MESSAGE" (String, optional): Custom label or title for the alarm (e.g. "Wake up", "Medicine").
  * "android.intent.extra.alarm.DAYS" (List<int>, optional): Weekdays for repeating alarm using Java Calendar constants:
    1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. E.g. [2, 3, 4, 5, 6] for Mon-Fri.
  * "android.intent.extra.alarm.VIBRATE" (bool, optional): Whether device vibrates when alarm triggers (default true).
  * "android.intent.extra.alarm.SKIP_UI" (bool, optional): true to create alarm silently without opening Clock app; false to open Clock app with fields pre-filled.
  * "android.intent.extra.alarm.RINGTONE" (String, optional): Custom ringtone sound URI or "silent".

2. SHOW ALARMS:
- action: "intent"
- android_action: "android.intent.action.SHOW_ALARMS"
- Behavior: Opens Clock app directly on the Alarms tab. No extras required.

3. DISMISS ALARM:
- action: "intent"
- android_action: "android.intent.action.DISMISS_ALARM"
- Eligible Extras:
  * "android.intent.extra.alarm.SEARCH_MODE" (String, optional): "android.next" (default upcoming), "android.all", "android.label", or "android.time".
  * "android.intent.extra.alarm.MESSAGE" (String, optional): Alarm label to match when search mode is "android.label".
  * "android.intent.extra.alarm.SKIP_UI" (bool, optional): true to dismiss silently.

4. START COUNTDOWN TIMER:
- action: "intent"
- android_action: "android.intent.action.SET_TIMER"
- Behavior: Directly starts a countdown timer.
- Eligible Extras:
  * "android.intent.extra.alarm.LENGTH" (int, required): Duration of timer in SECONDS (e.g. 60 for 1 min, 300 for 5 min, 1800 for 30 min).
  * "android.intent.extra.alarm.MESSAGE" (String, optional): Custom label for timer (e.g. "Tea", "Workout").
  * "android.intent.extra.alarm.SKIP_UI" (bool, optional): true to start countdown immediately; false to open Clock app timer UI.

5. SHOW / DISMISS TIMERS:
- Show Timers: android_action: "android.intent.action.SHOW_TIMERS" (no extras).
- Dismiss Timer: android_action: "android.intent.action.DISMISS_TIMER" (extras: "android.intent.extra.alarm.SKIP_UI": true).''',

  'calendar': '''### Android Calendar Event Intent Specification (`android.provider.CalendarContract`)

1. CREATE / INSERT CALENDAR EVENT:
- action: "intent"
- android_action: "android.intent.action.INSERT"
- type: "vnd.android.cursor.item/event"
- CRITICAL BEHAVIOR & USER CONFIRMATION:
  Android security sandbox does NOT permit background/silent insertion of calendar events via standard intents.
  This intent launches the Calendar event editor screen pre-filled with the provided event details.
  The user MUST review and tap "Save" to commit the event to their calendar (similar to email compose).
- Eligible Extras:
  * "title" (String, recommended): Title or summary of the event (e.g. "Dentist Appointment", "Sprint Planning").
  * "description" (String, optional): Detailed notes, agenda, or description for the event.
  * "eventLocation" (String, optional): Physical venue, room, or location link (e.g. "Conference Room 3B", "123 Main St").
  * "beginTime" (int/long, recommended): Start time in epoch MILLISECONDS UTC (e.g. 1789419587337).
  * "endTime" (int/long, recommended): End time in epoch MILLISECONDS UTC. Must be >= beginTime.
  * "allDay" (bool, optional): true if event is an all-day event (default false). When true, beginTime should align with UTC midnight.
  * "android.intent.extra.EMAIL" (String, optional): Comma-separated email addresses of attendees to invite (e.g. "alex@example.com, sam@example.com").
  * "rrule" (String, optional): RFC 5545 recurrence rule (e.g. "FREQ=DAILY", "FREQ=WEEKLY;BYDAY=MO,WE,FR", "FREQ=MONTHLY").
  * "availability" (int, optional): Availability status: 0 = Busy (default), 1 = Free, 2 = Tentative.
  * "accessLevel" (int, optional): Privacy level: 0 = Default, 1 = Confidential, 2 = Private, 3 = Public.

2. VIEW CALENDAR AT SPECIFIC DATE/TIME:
- action: "intent"
- android_action: "android.intent.action.VIEW"
- url: "content://com.android.calendar/time/<epoch_milliseconds>"
- Behavior: Opens Calendar app focused on the specified date/time view.

3. VIEW / EDIT EXISTING EVENT:
- action: "intent"
- android_action: "android.intent.action.VIEW" (to view) or "android.intent.action.EDIT" (to edit)
- url: "content://com.android.calendar/events/<event_id>"
- Behavior: Opens the specified event in the Calendar app.''',

  'timer': '''### Android Countdown Timer Intent Specification (`android.provider.AlarmClock`)

1. START COUNTDOWN TIMER:
- action: "intent"
- android_action: "android.intent.action.SET_TIMER"
- Behavior: Starts a countdown timer in the default Clock app. If "android.intent.extra.alarm.SKIP_UI" is true, starts countdown immediately in the background with a system toast notification. If false, opens Clock app timer screen.
- Eligible Extras:
  * "android.intent.extra.alarm.LENGTH" (int, required): Duration of timer in SECONDS (e.g. 60 for 1 min, 300 for 5 min, 1800 for 30 min).
  * "android.intent.extra.alarm.MESSAGE" (String, optional): Custom label for timer (e.g. "Pasta", "Laundry").
  * "android.intent.extra.alarm.SKIP_UI" (bool, optional): true to start countdown immediately; false to open Clock app timer UI.

2. SHOW TIMERS:
- action: "intent"
- android_action: "android.intent.action.SHOW_TIMERS"
- Behavior: Opens Clock app directly on the Timers tab. No extras required.

3. DISMISS TIMER:
- action: "intent"
- android_action: "android.intent.action.DISMISS_TIMER"
- Eligible Extras:
  * "android.intent.extra.alarm.SKIP_UI" (bool, optional): true to dismiss silently.

(See also: "alarm" for full alarm, snooze, and repeating schedule specifications).''',

  'location': '''### Android Maps, Location & Navigation Intent Specification

1. LIVE TURN-BY-TURN NAVIGATION (`google.navigation:`):
- action: "open_url" (or "intent")
- url: "google.navigation:q=<destination>&mode=<mode>&avoid=<avoid>"
- Parameters:
  * q (required): Destination name, street address, or coordinates (e.g. "google.navigation:q=Statue+of+Liberty" or "google.navigation:q=37.7749,-122.4194"). Use "+" or "%20" for spaces.
  * mode (optional): Travel mode:
    - "d" = Driving (default)
    - "w" = Walking
    - "b" = Bicycling
    - "l" = Two-wheeler
  * avoid (optional): Route features to avoid, comma-separated:
    - "t" = Tolls
    - "h" = Highways
    - "f" = Ferries
- Examples:
  * google.navigation:q=Golden+Gate+Bridge&mode=d (Drive to Golden Gate Bridge)
  * google.navigation:q=Central+Park&mode=w (Walk to Central Park)
  * google.navigation:q=Airport&avoid=t,h (Drive to airport avoiding tolls & highways)

2. NEARBY SEARCH & PLACE SEARCH (`geo:0,0?q=`):
- action: "open_url" (or "intent")
- url: "geo:0,0?q=<query>"
- Behavior: Searches places/businesses relative to the user's CURRENT GPS location. Google Maps uses its own location fix, so Errand does not need location permissions!
- Examples:
  * geo:0,0?q=restaurants (Find restaurants near current location)
  * geo:0,0?q=pharmacy+near+me (Find nearby pharmacies)
  * geo:0,0?q=1600+Amphitheatre+Parkway,+Mountain+View,+CA (Search specific address)

3. CENTER MAP ON SPECIFIC COORDINATES (`geo:lat,lng?z=`):
- action: "open_url" (or "intent")
- url: "geo:<lat>,<lng>?z=<zoom>"
- Parameters:
  * lat, lng: Decimal latitude and longitude coordinates.
  * z (optional): Zoom level from 1 (whole earth) to 23 (building level). City view is 12-15.
- Examples:
  * geo:37.7749,-122.4194?z=15 (View San Francisco)
  * geo:40.7128,-74.0060?q=coffee (Search coffee around New York coordinates)
  * geo:0,0?q=37.7749,-122.4194(Meeting+Point) (Drop a custom labeled pin)

4. GOOGLE STREET VIEW (`google.streetview:`):
- action: "open_url" (or "intent")
- url: "google.streetview:cbll=<lat>,<lng>&cbp=1,<yaw>,,<pitch>,<zoom>"
- Parameters:
  * cbll: Latitude and longitude of the camera position.
  * cbp (optional): Orientation parameters (1,yaw,,pitch,zoom).
- Example:
  * google.streetview:cbll=27.1751,78.0421 (Street view of Taj Mahal)''',

  'maps': '''### Android Maps, Location & Navigation Intent Specification
(Alias for "location" — see full specification under topic "location").''',
};

/// Internal registry of intent documentation and schemas for action: "docs".
/// Keys are intent categories/names (e.g. 'alarm', 'calendar', 'timer').
final Map<String, String> intentDocs = Map<String, String>.from(kDefaultIntentDocs);

ToolCallResult _intentDocs(ToolCall call) {
  final name = (call.arguments['name'] as String?)?.trim().toLowerCase();
  if (name == null || name.isEmpty) {
    if (intentDocs.isEmpty) {
      return ToolCallResult(
        id: call.id,
        ok: true,
        output: 'No intent documentation currently available.',
      );
    }
    return ToolCallResult(
      id: call.id,
      ok: true,
      output:
          'Available intent doc topics: ${intentDocs.keys.join(', ')}. Pass "name" to view definition.',
    );
  }

  final doc = intentDocs[name];
  if (doc != null) {
    return ToolCallResult(id: call.id, ok: true, output: doc);
  }

  final available = intentDocs.keys.isEmpty
      ? 'none'
      : intentDocs.keys.join(', ');
  return ToolCallResult.failure(
    call.id,
    'No intent documentation found for "$name". Available topics: $available.',
  );
}

class _ExtrasParseResult {
  final Map<String, dynamic>? values;
  final String? error;

  const _ExtrasParseResult({this.values, this.error});
}

_ExtrasParseResult _parseExtras(dynamic raw) {
  if (raw == null) return const _ExtrasParseResult();
  if (raw is! Map) {
    return const _ExtrasParseResult(
      error: '"extras" must be an object whose values are typed primitives',
    );
  }

  final result = <String, dynamic>{};
  final invalid = <String>[];
  raw.forEach((key, val) {
    if (val == null) return;
    if (key is String && _isSupportedExtraValue(val)) {
      result[key.toString()] = val;
    } else {
      invalid.add(key?.toString() ?? '<null>');
    }
  });

  if (invalid.isNotEmpty) {
    return _ExtrasParseResult(
      error:
          'Unsupported intent extra value for key(s): ${invalid.join(", ")}. '
          'Use only string, boolean, integer/number, or string-array values.',
    );
  }
  return _ExtrasParseResult(values: result.isEmpty ? null : result);
}

bool _isSupportedExtraValue(dynamic value) {
  if (value == null) return false;
  if (value is String || value is bool || value is num) return true;
  if (value is List) return value.every((item) => item is String);
  return false;
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
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: 'Opened $key settings ($res)$notice',
    );
  } on PlatformException catch (e) {
    return ToolCallResult.failure(
      call.id,
      'Failed to open $key settings: ${e.message}',
    );
  }
}

Future<ToolCallResult> _openFile(
  ToolCall call,
  IntentService svc,
  A11yService? a11y,
) async {
  final rawPath =
      (call.arguments['path'] as String?)?.trim() ??
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
  final parsedExtras = _parseExtras(call.arguments['extras']);
  if (parsedExtras.error != null) {
    return ToolCallResult.failure(call.id, parsedExtras.error!);
  }
  final extras = parsedExtras.values;

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

Future<ToolCallResult> _openUrl(
  ToolCall call,
  IntentService svc,
  A11yService? a11y,
) async {
  final rawUrl =
      (call.arguments['url'] as String?)?.trim() ??
      (call.arguments['path'] as String?)?.trim();

  if (rawUrl == null || rawUrl.isEmpty) {
    // If query was passed (e.g. web search), construct Google search URL
    final query = (call.arguments['query'] as String?)?.trim();
    if (query != null && query.isNotEmpty) {
      final searchUrl =
          'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}';
      final pkg = call.arguments['package'] as String?;
      try {
        final res = await svc.launchAction(
          'open_url',
          data: searchUrl,
          package: pkg,
        );
        final notice = await _maybePausedNotice(
          a11y,
          'web search for "$query"',
        );
        return ToolCallResult(
          id: call.id,
          ok: true,
          output: 'Searched web for "$query": $res$notice',
        );
      } on PlatformException catch (e) {
        return ToolCallResult.failure(
          call.id,
          'Web search failed: ${e.message}',
        );
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
        call.id,
        'Blocked unsafe URL scheme: "$scheme"',
      );
    }
  }

  final pkg = call.arguments['package'] as String?;
  final parsedExtras = _parseExtras(call.arguments['extras']);
  if (parsedExtras.error != null) {
    return ToolCallResult.failure(call.id, parsedExtras.error!);
  }
  final extras = parsedExtras.values;

  try {
    final res = await svc.launchAction(
      'open_url',
      data: url,
      package: pkg,
      extras: extras,
    );
    final notice = await _maybePausedNotice(a11y, 'URL $url');
    return ToolCallResult(
      id: call.id,
      ok: true,
      output: 'Opened URL: $url ($res)$notice',
    );
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
      final suggestions = matches
          .map((a) => '- ${a.label} (${a.package})')
          .join('\n');
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

Future<ToolCallResult> _genericIntent(
  ToolCall call,
  IntentService svc,
  A11yService? a11y,
) async {
  final androidAction = (call.arguments['android_action'] as String?)?.trim();
  final data =
      (call.arguments['url'] as String?)?.trim() ??
      (call.arguments['path'] as String?)?.trim();
  final pkg = (call.arguments['package'] as String?)?.trim();
  final type = (call.arguments['type'] as String?)?.trim();
  final parsedExtras = _parseExtras(call.arguments['extras']);
  if (parsedExtras.error != null) {
    return ToolCallResult.failure(call.id, parsedExtras.error!);
  }
  final extras = parsedExtras.values;

  if ((data == null || data.isEmpty) &&
      (androidAction == null || androidAction.isEmpty)) {
    return ToolCallResult.failure(
      call.id,
      'Missing intent target. Provide "android_action" and/or "url" (data URI). '
      'Provide exact target-specific extras in "extras"; Errand does not infer them.',
    );
  }

  try {
    final res = await svc.launchAction(
      'intent',
      androidAction: androidAction,
      data: data,
      package: pkg,
      extras: extras,
      type: type,
    );
    final notice = await _maybePausedNotice(a11y, 'custom intent');
    return ToolCallResult(
      id: call.id,
      ok: true,
      output:
          'Dispatched custom intent ($res)$notice. Android launch succeeded, but the target app\'s '
          'operation or saved state is not verified by this tool.',
    );
  } on PlatformException catch (e) {
    return ToolCallResult.failure(
      call.id,
      'Failed custom intent: ${e.message}',
    );
  }
}
