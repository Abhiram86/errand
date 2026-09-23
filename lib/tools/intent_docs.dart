import "package:errand/agent/tool.dart";
import "package:errand/types/tool.dart";

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

ToolCallResult handleIntentDocs(ToolCall call) {
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
