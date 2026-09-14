# Next Plan — Status & Roadmap

> **Updated Sep 2026.** P0, P1, P1.5, P2, P3 (multimodality), P4 (refactor & hardening), P5a (on-device shell & workspace retirement), and v0.5.6 (intent docs, tool grouping UI, keyed provider priority, entrypoint modularization) are all **SHIPPED** (v0.5.6).
> **Active Milestone:** **P5b — Global Memory System & Persistent Knowledge Tool** (schema v5).
> **Upcoming Milestone:** **P6a — Embedded Browser Agent Tools** (in-app webview, DOM JS bridge + visual fallback).

---

## 🧭 Active & Upcoming Roadmap

### 🟡 P5b — Global Memory System & Persistent Knowledge Tool (NEXT — schema v5)

Cross-conversation persistent memory giving Errand long-term recall of user preferences, project facts, device context, and learned guidelines.

1. **Database Persistence (Schema v5 Migration):**
   - New `memories` table in `lib/services/database.dart`:
     - `id` (Text, UUID primary key)
     - `key` (Text, nullable unique slug for keyed values like `user_name`, `preferred_model`, `work_dir`)
     - `content` (Text, full memory text or fact description)
     - `tags` (Text, JSON array or delimited tags for category filtering, e.g. `["preferences", "coding"]`)
     - `created_at` / `updated_at` (DateTime, sorting and obsolescence tracking)
   - Clean Drift schema migration from v4 (`attachedUrisJson`) to v5 with full test coverage (`test/database_test.dart`).

2. **Agent Tool (`memory` in `lib/tools/memory_tool.dart`):**
   - `action: "save"` — Save a new memory or fact with optional key and tags.
   - `action: "recall"` — Search existing memories using query matching across content, keys, and tags.
   - `action: "update"` — Update content or tags of an existing memory by ID or key.
   - `action: "delete"` — Remove a specific memory or purge by tag/key.
   - `action: "list"` — Browse recent memories with limit and tag filters.

3. **System Prompt Knowledge Digest (Passive Awareness):**
   - Inject a compact, token-budgeted "Known Facts" block into `_systemPromptFor` / `SystemPromptService`.
   - Core preferences and recent memories are passively visible to the agent on every turn without requiring explicit `memory recall` round-trips.

4. **User Privacy & Control:**
   - Dedicated Memory Management screen or Settings sheet tab allowing users to inspect, edit, manually add, or purge memories.
   - Transparent logging: whenever the agent writes or updates a memory, it is clearly reported in the tool call output.

---

### 🌐 P6 — Embedded Web Agent Tools (Closing the Lite vs. Full Gap)

Goal: Enable autonomous, safe web navigation and interaction directly within Errand, eliminating the need to bounce the user to external browsers while remaining fully functional on both Full and Lite flavors (zero accessibility permissions required).

#### 🔵 P6a — Embedded Browser Agent Tools
1. **Interactive In-App Web View:**
   - Dedicated in-app browser sheet/view via `webview_flutter` or native platform view.
   - Allows live observation: the user can watch the agent navigate, fill inputs, and click elements directly inside the Errand UI.

2. **Dual-Mode Control (DOM JavaScript + Visual Fallback):**
   - **Primary (Direct JavaScript Bridge):** High-speed, deterministic DOM interaction via JavaScript evaluation:
     - Read visible page text, headings, links, and structured DOM outlines.
     - Query and validate CSS / XPath selectors.
     - Populate form fields, select options, and dispatch click/submit events.
     - Fast, token-efficient, and independent of device display scaling.
   - **Secondary (Visual Screenshot Fallback):**
     - Capture rendered page screenshots from the WebViewController for multimodal models.
     - Activates when selectors fail, target elements reside within complex shadow DOMs, or interactions involve HTML5 Canvas components.
   - **Execution Discipline:** JavaScript evaluation is attempted first; vision fallback triggers only when DOM queries fail or yield ambiguous matches.

3. **Security, Sandboxing & Safety Policy:**
   - **Origin & Scheme Lockdown:** Strictly whitelist `http` and `https` protocols; block arbitrary `intent://`, `file://`, and `javascript:` scheme navigations from untrusted pages.
   - **Draft & Confirmation Policy:** Sensitive or irreversible actions (form submissions, logins, purchases, data updates) require user confirmation under the Draft model: the agent pre-fills the form and requests the user to approve or submit.
   - **Session Isolation:** Configurable ephemeral (incognito) vs. persistent session storage with one-tap cookie and cache clearing.

---

### 📦 Backlog & Future Items

- **Safe File Editing Tool (`write` / `edit_file`):** In-place file modification with structured diff preview, user approval gating, and atomic backup/undo mechanisms.
- **Local Semantic Retrieval:** On-device embeddings / SQLite FTS5 for local documents and memory recall.
- **Stream-Stall Watchdog:** SSE inactivity transformer for `chatStream` to cleanly recover from frozen network sockets.

---

## ✅ Shipped Milestones

### ✅ P0 — Android Intent Tool & Native System Surface
- **Curated Intent Actions:** Comprehensive intent surface (`open_file`, `open_url`, `open_app`, `settings`, `intent`, `docs`) covering alarms, timers, calendar entries, sharing, maps, email, media playback, uninstall, and settings panels.
- **Generic Escape Hatch:** Normalized `action: "intent"` accepts arbitrary `android_action` strings with typed extras mapping (`int`, `double`, `bool`, `String`) for third-party apps without code changes.
- **On-Demand Intent Documentation (`docs`):** Agent inspects exact Android actions, URIs, and extra schemas for `alarm`, `timer`, `location`, `calendar`, `web_search`, `email`, and `media_capture` before dispatching.
- **System Hardening:** Async native error handling (`NO_HANDLER`, `NO_PKG`), strict URL auto-prefix validation, RFC-6068 email queries, `FileProvider` URI resolution, BAL-safe launch (`PendingIntent` + a11y context fallback), and selective `bringToFront`.
- **App Discovery & Alias Matching:** SQLite-cached launcher package inventory with fuzzy alias resolution (e.g. YouTube Music, BookMyShow) and top-10 suggestions on launch failures.

### ✅ P1 — Context Budgeting, History Compaction & Pagination
- **Token-Based Context Budgeting:** Dynamic `ContextBudget` calibrated per model (~3.8 chars/token, model `contextSize`, reserving `min(16K, 25%)` output tokens with `models.dev` fallback).
- **Auto-Compaction & Truncation:** Pre-turn and mid-run LLM history compaction with deterministic fallbacks under a 60-second timeout; persisted `CompactedNoticeMessage` dividers preserve pre-compaction turns without re-sending them.
- **Windowed Message & Sidebar Loading:** Initial 50-message conversation window with prepending viewport-anchored scroll pagination (`loadOlderMessages`); sidebar cursor-based pagination for recents (`PagedFetcher<T>`).
- **Merge-Safe Database Upserts:** Message-level upserting in `saveConversation` ensuring out-of-window messages remain intact.

### ✅ P1.5 — Conversational UX, Control & Resiliency
- **Abortable Cancellation (Stop Button):** Dynamic send/stop button toggling with cancel flags threaded into SSE streaming and turn boundaries; preserves partial output.
- **Message Editing & Branching:** Edit user message with cascade deletion of subsequent turns (`_truncateFrom`); regenerate response from last user turn.
- **Voice Input:** Integrated `speech_to_text` wrapping Android's built-in `SpeechRecognizer` with first-use language selection and persistent preference storage.
- **Foreground Execution Guard:** Active `dataSync` Foreground Service keeps SSE streams alive when intent launches push Errand to the background.
- **Network Resilience & Error Policy:** 3-attempt exponential backoff with `Retry-After` honoring for API calls; clear separation between transport errors (transient SnackBars) and tool errors (inline context).

### ✅ P2 — Accessibility Service & Screen Automation (Tier S & Draft Tier A)
- **Kotlin Accessibility Service:** `ErrandAccessibilityService` with `canRetrieveWindowContent`, `canPerformGestures`, and `canTakeScreenshot` capabilities; method channel `"a11y"` mirroring `"intent"`.
- **Screen Outline Tool (`screen`):** Compact outline serialization with viewport partitioning (visible items emitted first in visual reading order; off-screen nodes grouped under `--- Off-screen ---`); TalkBack boilerplate stripping and list compression.
- **Global Actions:** Back, home, recents, notification shade, lock screen, and screenshot capture.
- **Gated Draft-Mode Gestures (`act`):** Tap by label with commit refusal, `ACTION_SET_TEXT` typing with password/OTP field refusal, and directional scrolling with deterministic `at_end` detection.
- **Extended Turn Cap:** Agent loop cap extended to 72 turns with mid-run compaction.
- **Lifecycle & Privacy:** Auto-disables on app removal and finish; cold-start restricted settings guidance; Settings sheet Enable/Disable toggle.

### ✅ P3 — Media Multimodality & Attachment Pipeline
- **Integrated Media Reading:** `read` tool directly processes media (`kMediaFormats`: jpg, png, webp, gif, wav, mp3, mp4, webm, mov up to 20 MiB) into OpenAI-compatible data URLs.
- **Capability Gating:** `ModelCatalogService.supportsInput` checks model capability before dispatching multimodal payloads.
- **Composer Attachment Workflow:** Multi-file picker (`+`), staging card preview, and schema v4 ordered tracking (`ConversationMessages.attachedUrisJson`).
- **Discovery Tool:** `attached_files` tool provides instant inventory of conversation attachments. Verified with 81 unit/integration tests.

### ✅ P4 — Architecture Refactor & Operational Hardening (v0.5.0 – v0.5.2)
- **P4a Service Refactor (v0.5.0):** Systematic refactoring across all core modules (`model_catalog`, `tavily_client`, `workspace`, document readers, `intent_service`, `llm_client`, `agent_loop`, `database`, `a11y_service`, and UI) maintaining strict backward compatibility.
- **Dual Build Flavors (v0.5.2):** Full flavor retains accessibility automation for sideloaders; Lite flavor strips the accessibility service entirely from the manifest for zero-friction distribution.
- **Large Output Spill Caching:** `ToolOutputFileService` spills command/tool outputs exceeding 6k characters into temporary cache files (512 KB cap, 10-minute TTL, max 50 files) with head/tail previews and direct `read` cache resolution.
- **Heavy Tool `grep` Filtering:** Optional `grep` parameter for `screen`, `read`, and `workspace` tools with ReDoS protection and match limits.
- **Resilient Web & Visual Fallbacks (v0.5.1):** Offline `webfetch` via `reader_mode` + `html2md` fallback; accessibility screenshot capture; background model catalog prefetching and live `ModelPicker` updates.

### ✅ P5a — On-Device Shell Execution Tool (`/system/bin/sh`) (v0.5.5)
- **Direct Shell Invocation:** `ShellService` and `bashTool` execute on-device commands via `/system/bin/sh` using `Process.start` in `dart:io`.
- **Toybox / Toolbox Utility Suite:** Instant access to CLI utilities (`ls`, `cat`, `grep`, `find`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head`, `tail`, `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `du`, `ps`).
- **Directory Persistence:** Automatically tracks and mutates `WorkingDirectory.current` across turns and file tools.
- **Safety Policy:** Strictly blocks privilege escalation (`su`/`sudo`), reboot/shutdown, and fork bombs. Destructive mutations (`rm -rf`, wildcards) enforce Draft confirmation (`confirm_destructive: true`).
- **Workspace Tool Retirement:** Standalone `workspace` router retired from defaults; folder exploration unified under `bashTool`.

### ✅ v0.5.6 — Intent Documentation, Tool Call Grouping UI & Modularity
- **Intent Documentation Action:** Added `intent(action: "docs", name: "...")` for schema inspection across core Android actions.
- **Typed Extras Support:** Normalized integer lists and primitive types in platform channels (`MainActivity.kt`).
- **Grouped Tool Call UI (`ToolGroupBubble`):** Consecutive tool executions grouped into a unified timeline card with animated status transitions (`running`, `completed`, `failed`), step counter badges, and nested collapsible accordions.
- **Keyed Provider Prioritization:** Providers with configured API keys appear first in the LLM selection UI.
- **Entrypoint Modularization:** Decomposed `lib/main.dart` into `lib/bootstrap.dart`, `lib/app.dart`, and `lib/screens/chat_screen.dart`.
