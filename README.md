# Errand

<p align="center">
  <img src="demo/errand_demo.gif" alt="Errand demo" width="320">
</p>

<p align="center">
  <b>An on-device AI agent for Android.</b><br>
  Chat with frontier models that can use your phone as hands: read files, run shell commands,
  browse the web, manage memories, and run scheduled background tasks — with you in control.
</p>

---

## What it does

Errand connects to AI models through your own API keys (OpenRouter by default, any OpenAI-compatible endpoint) and gives them a toolbox that runs **on your phone**:

- **Ask & do** — "summarize this PDF", "find my largest downloads", "watch this product page and tell me when the price drops"
- **Background tasks** — one-off reminders and recurring autonomous jobs that run headlessly via Android alarms, save Markdown/HTML reports, and notify you on completion
- **Memory** — remembers your preferences across conversations; inspect or delete everything in Settings
- **Manage Tasks dashboard** — active, completed, failed, and unread runs with logs, file previews, and per-task model overrides

## How background tasks work

1. You ask ("remind me in 45 minutes", "every morning, brief me on tech news") and the agent creates a scheduled task — optionally pinned to a specific model or provider, overridable later per task.
2. At fire time Android wakes a background engine (no UI involved) that runs the task headlessly and saves a Markdown/HTML report.
3. You get a system notification; the Manage Tasks dashboard keeps every run, log, and report with previews.

## Chat extras

- **Tappable links** — web links open externally; `file://` links the agent drops for artifacts you asked it to create open in the in-app preview (Markdown/HTML) or your preferred viewer, sandboxed to your workspace.
- **Table copy** — assistant tables copy as Markdown *and* rich HTML, so they paste as real tables into Notes, Docs, and Notion.

## Two flavors: Full vs. Lite

|  | **Full** (`com.errand.errand`) | **Lite** (`com.errand.errand.lite`) |
|---|---|---|
| Screen reading & automation (`screen`, `screen_act`) | ✅ | ❌ |
| Embedded browser automation | ✅ | ✅ |
| Shell, files, memory, web search, intents | ✅ | ✅ |
| Background scheduled tasks | ✅ | ✅ |
| Accessibility permission | Required for screen tools | Never asked |

**Why two builds?** Screen automation needs Android's accessibility service — one of the most sensitive permissions on the platform, and rightly scary to grant. Rather than asking everyone to trust us with it, we ship Lite with that capability compiled out entirely: there is no code path that can read your screen, so there is nothing to trust. Choose Full only if you want the agent to see and operate other apps.

## Trust & privacy

Sideloaded automation apps deserve skepticism, so here's the full picture:

- **Your data stays on your device.** Conversations, memories, tasks, and logs live in a local SQLite database. There is no account, no cloud sync, no analytics.
- **Network access is limited to the services needed for the features you use:** your configured LLM provider and model catalog, Tavily or the fallback web-search service when web search or extraction is used, `models.dev` for model metadata, GitHub Releases for update checks and APK downloads, and websites you ask the agent or embedded browser to open. No account or analytics service is used, and conversations remain local.
- **API keys are encrypted** with AES-256-GCM before storage, with the key kept in a separate file — the database alone reveals nothing.
- **Destructive actions ask first.** Shell deletions, payments, sends, and other commit-type actions require your explicit confirmation; the agent prepares, you decide.
- **Permissions, justified:**
  - *All-files access* — the agent works with your real files (Documents, Downloads), not a sandbox copy.
  - *Accessibility (Full only)* — powers screen reading/automation; absent from Lite builds entirely.
  - *Alarms & notifications* — exact-time background tasks and their completion alerts.
  - *Microphone* — optional voice input only.
- **Updates** come from GitHub releases with per-ABI, per-flavor APK matching, size verification, and release notes shown after update.

## Configuration

Tap the gear icon in the app (or **Set API key** in the header on first run):

- **OpenRouter API key** (required) — enables chat; unlocks the live model catalog.
- **Tavily API key** (optional) — enables `websearch` / `webfetch`; everything else works without it.
- **Base URL** (optional) — point at any OpenAI-compatible endpoint (default `https://openrouter.ai/api/v1`).

On Android, grant all-files access when prompted so the agent can reach your workspace (defaults to `Documents/Errand`).

## For developers

```bash
flutter test          # run the full test suite
flutter analyze       # lint
flutter run --flavor full   # or lite
```

- `architecture.md` — full map of the implementation.
- `next_plan.md` — status and roadmap.
- Build flavors differ only by manifest/services: `Full` includes the accessibility service, `Lite` strips it.
