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
    DOCX, XLSX, PPTX (zip-bomb and size guarded).
  - `workspace` — `pwd` / `cd` / `list` / `find` over `/storage/emulated/0`
    with path-traversal guards.
  - `websearch` / `webfetch` — Tavily search + Markdown extraction.
  - `intent` — 5 core Android actions (`open_file` via FileProvider,
    `open_url`, `open_app`, `settings`, raw `android_action` hatch) with
    backward-compatible routing for legacy actions; UI toggles live in
    `act` now.
  - `screen` / `act` — optional accessibility-backed screen reading (compact
    outline of the active window) and Draft-mode interaction: tap labeled
    controls, type into focused fields, scroll. Commit-looking actions
    (Send/Pay/Delete…) are refused — Errand prepares, the user sends.
    Requires enabling Errand in Accessibility settings.
- **Context management** — token-based per-model budget (`ContextBudget`,
  reserve `min(16K, 25%)`) with automatic pre-turn + mid-step compaction
  (deterministic fallback), plus message windowing (newest 50 on open, paged
  scroll-up) and sidebar pagination.
- **Chat UI** — Material 3 dark theme, markdown rendering for assistant
  messages (code, tables, LaTeX), text selection, collapsible tool bubbles
  with re-open buttons for launch-style intents, searchable model picker.
- **Local persistence** — conversations/messages/attachments in Drift with
  merge-based saves, pinned favourites, recency-ordered sidebar.
- **In-app configuration** — API keys are entered in Settings (gear icon in
  the header), encrypted with AES-256-GCM, and stored in the app's SQLite
  database. No `.env` file is needed.

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
