# Handy Flutter

Handy is an on-device AI agent for Android: a streaming chat client with a
small custom agent loop that can read and navigate the shared storage, search
the web, understand structured documents, and drive Android apps/system
surfaces via intents. Everything except the LLM and web search runs on-device;
conversations are stored locally (Drift/SQLite) with no cloud sync.

## Features

- **Agent loop** (`lib/agent/`) — OpenAI-compatible tool-calling, up to 12
  turns per request, live streaming of text and reasoning deltas.
- **Tools**
  - `read` — bounded byte-range reads for text; logical pagination for PDF,
    DOCX, XLSX, PPTX (zip-bomb and size guarded).
  - `workspace` — `pwd` / `cd` / `list` / `find` over `/storage/emulated/0`
    with path-traversal guards.
  - `websearch` / `webfetch` — Tavily search + Markdown extraction.
  - `intent` — 17 curated Android actions (open URLs/apps/maps, dial, email,
    alarms/timers, calendar events, media playback, share, wallpaper,
    uninstall, settings pages/panels, dark-mode toggle) plus a generic raw
    `android_action` escape hatch.
- **Context management** — history truncation against a 200K-char soft limit
  with atomic tool batches, message windowing (newest 50 on open, paged
  scroll-up), and sidebar pagination.
- **Chat UI** — Material 3 dark theme, markdown rendering for assistant
  messages (code, tables, LaTeX), text selection, collapsible tool bubbles
  with re-open buttons for launch-style intents, searchable model picker.
- **Local persistence** — conversations/messages/attachments in Drift with
  merge-based saves, pinned favourites, recency-ordered sidebar.

## Run with local environment

Flutter does not load `.env` files automatically. Start the app with:

```bash
flutter run --dart-define-from-file=.env
```

The local `.env` file should define:

```text
OPENROUTER_API_KEY=...
TAVILY_API_KEY=...
HANDY_BASE_URL=https://openrouter.ai/api/v1
HANDY_MODEL=openai/gpt-4o-mini
```

`HANDY_BASE_URL`, `HANDY_MODEL`, and `TAVILY_API_KEY` are optional; the app
defaults to OpenRouter and falls back to a built-in model list. Web tools are
disabled without a Tavily key.

On Android, the app requests all-files access and operates under
`/storage/emulated/0`; the agent refuses absolute paths outside its injected
workspace. The system dark-mode toggle works best with a one-time grant:

```bash
adb shell pm grant com.handy.handy_flutter android.permission.WRITE_SECURE_SETTINGS
```

Run the test suite with:

```bash
flutter test
```

See `architecture.md` for a full map of the implementation and
`next_plan.md` for status and the roadmap.
