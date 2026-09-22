# Errand (Flutter)

<p align="center">
  <img src="demo/demo.gif" alt="Errand demo" width="320">
</p>

Errand is an on-device AI agent for Android: a streaming chat client with a
small custom agent loop that can read and navigate the shared storage, search
the web, understand structured documents, and drive Android apps/system
surfaces via intents. Everything except the LLM and web search runs on-device;
conversations are stored locally (Drift/SQLite) with no cloud sync.

## Features

- **Agent loop** (`lib/agent/`) — OpenAI-compatible tool-calling, up to 72
  turns per request, live streaming of text and reasoning deltas, with
  automatic LLM-driven context compaction past the model's token budget.
- **Tools**
  - `read` — bounded byte-range reads for text; logical pagination for PDF,
    DOCX, XLSX, PPTX (zip-bomb and size guarded). Optional `grep` (regex) to
    pull only matching lines with 1-based line numbers; unpaginated length
    expands to 512 KB.
  - `bash` — on-device shell execution via `/system/bin/sh` with access to
    Android Toybox/Toolbox utilities (`ls`, `find`, `cat`, `grep`, `sed`, `awk`,
    `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `ps`, etc.). Enforces 30s
    timeouts, Draft safety policies (blocks fork bombs and su/root; requires
    confirmation for destructive `rm -rf`), and automatic directory persistence
    on `cd` or `working_directory`.
  - `browser` — autonomous, in-app web navigation directly within Errand on
    both Full and Lite flavors (zero accessibility permissions required).
    Features direct DOM JavaScript evaluation via JS bridge, accessibility tree
    snapshots, visual screenshot fallback for multimodal models, text extraction,
    and adaptive preview zoom (`0.80`). Accompanied by a responsive morphing UI
    (`BrowserWidget`) spanning compact dock bar (50px), preview card, and
    full-screen view with custom navigation controls and composer-focus isolation.
  - `memory` — cross-conversation persistent memory (`memories` table in Drift,
    schema v5) for long-term recall of user preferences, device context, and
    guidelines across sessions (`save`, `recall`, `update`, `delete`, `list`),
    with passive knowledge digests injected into the prompt and a management UI in Settings.
  - `websearch` / `webfetch` — Tavily search + Markdown extraction.
  - `schedule_task` — background autonomous task scheduling (`create`, `edit`, `delete`, `get`, `list`, `logs`). Executes tasks headlessly via native Android `AlarmManager`, collecting HTML/Markdown reports in `.scratch/` and firing system notifications upon completion.
  - `intent` — 6 core Android actions (`open_file` via FileProvider,
    `open_url`, `open_app`, `settings`, raw `android_action` hatch, and `docs`
    for on-demand schema lookups across alarms, timers, calendar, and location/maps).
    Supports typed extras (primitives, string lists, and integer lists) and
    backward-compatible routing for legacy actions. All open-style actions
    append a notice when screen access is off.
  - `screen` / `screen_act` — optional accessibility-backed screen reading (compact
    outline of the active window) and Draft-mode interaction: tap labeled
    controls, type into focused fields, scroll. Commit-looking actions
    (Send/Pay/Delete…) are refused — Errand prepares, the user sends.
    Requires enabling Errand in Accessibility settings.
  - `grep` filter — optional case-insensitive regex/substring on `screen` (outline),
    `read` (file content with line numbers),
    and `screen_act` (then_read). ReDoS-safe: overlong / nested-quantifier patterns
    fall back to literal; match cap 200 with overflow note.
- **Large output spill** — `ToolOutputFileService` spills outputs > 6k chars to
  `cache/tool_outputs/tool-{id}_{hash}-output.txt` (512 KB store cap, max 50
  files, 10-min TTL). Returns a compact head/tail preview with header block
  reservation and the file path; the `read` tool opens spilled files directly.
- **Context management** — token-based per-model budget (`ContextBudget`,
  reserve `min(16K, 25%)`) with automatic pre-turn + mid-step compaction
  (deterministic fallback), plus message windowing (newest 50 on open, paged
  scroll-up) and sidebar pagination.
- **Chat UI** — Material 3 dark theme, markdown rendering for assistant
  messages (code, tables, LaTeX), text selection, searchable model picker
  with release date sorting and dynamic provider defaults. Sequential tool
  calls automatically group into clean collapsible bubbles with live
  streaming summaries. Multi-line composer with an animated multi-color
  glowing border while the assistant is processing turns (zero idle battery
  overhead). Unified compact options modal sheet (75% screen height cap)
  for chat actions, message editing, and message retry. Assistant message tables
  support cell truncation, horizontal scrolling, and quick copying.
- **Manage Tasks dashboard** — dedicated full-screen task manager accessible from
  the sidebar. Inspect active, completed, failed, and unread tasks with execution logs,
  time filters, status controls, and in-app file previews.
- **Local persistence** — conversations/messages/attachments/memories/scheduler_tasks in Drift (schema v7) with
  merge-based saves, pinned favourites, recency-ordered sidebar.
- **In-app configuration** — API keys are entered in Settings (gear icon in
  the header), encrypted with AES-256-GCM, and stored in SQLite. Providers with
  active keys automatically take priority in the model picker while preserving
  stable relative order. Settings → Tools tab shows screen-access state,
  Enable/Disable buttons, Tavily key, and Memory Management.
- **Background OTA updates & release notes** — periodic background checks against GitHub releases (`GET /repos/Abhiram86/errand/releases/latest`) on a 2-hour cadence, plus a manual check action in the sidebar. Matches device ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) and flavor (`full` vs `lite`), streams APKs with atomic `.tmp` download and size verification, caches with 2-day TTL in SQLite (`pref.app_update_info`), and presents a floating pill under the model picker for 1-tap package installation. Automatically detects the first launch after an update to show parsed release notes (suppressed on fresh installs), with a manual release notes button in the sidebar header and auto-cleanup of stale downloaded APKs.

## Flavors (Full vs. Lite)

Errand is distributed in two build flavors:

- **Full** (`com.errand.errand`, app name `Errand`): Includes the complete feature set. Declares the Android accessibility service in its manifest, enabling the `screen` and `screen_act` tools for reading on-screen content, tapping UI elements, typing, and taking screenshots. Settings includes screen access controls and cold-start guidance for enabling the service.
- **Lite** (`com.errand.errand.lite`, app name `Errand Lite`): Completely removes the accessibility service declaration from the Android manifest. It runs without asking for or relying on accessibility permissions. The `screen` and `screen_act` tools are excluded from the agent tool registry. It handles in-app web browser automation (`browser`), on-device bash shell execution (`bash`), structured document reading (PDF, DOCX, XLSX, PPTX), memory persistence (`memory`), web search and extraction, and system intents (`open_app`, `open_file`, `open_url`, `settings`). It also includes on-device installed app caching with alias resolution, fuzzy matching for failed launches, and selective bring-to-front behavior when the agent produces follow-up responses.

## Configuration

Keys are configured at runtime in the app — tap the gear icon (or
**Set API key** in the header when no key exists yet):

- **OpenRouter API key** (required) — enables chat; the model picker loads
  the live catalog once set.
- **Tavily API key** (optional) — enables the `websearch` / `webfetch`
  tools; without it they fail cleanly and chat keeps working.
- **Base URL** (optional) — override for OpenAI-compatible endpoints;
  defaults to `https://openrouter.ai/api/v1`.

Secrets are AES-GCM encrypted before storage; the encryption key lives in a
separate file (`<app-support>/errand.key`), so the database alone contains
nothing readable. Preferences (voice-input locale, last-selected model,
prompt-dismissed flags) live in the same SQLite store as plain values.

On Android, the app requests all-files access and operates under
`/storage/emulated/0`; the agent refuses absolute paths outside its injected
workspace. The system dark-mode toggle works best with a one-time grant:

```bash
adb shell pm grant com.errand.errand android.permission.WRITE_SECURE_SETTINGS
```

Run the test suite with:

```bash
flutter test
```

See `architecture.md` for a full map of the implementation and
`next_plan.md` for status and the roadmap.
