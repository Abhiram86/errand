# Next Plan — Roadmap (live work only)

> State Oct 2026: heading to **v0.7.5 (lite-only)**. Schema v10. ~780 tests, analyzer clean.
> Shipped history (P0–P15, P13.6.*, all DONE sections) was removed — it is in git history, not here.
> `R2-*` IDs refer to the deleted Round-2 review; only open/partial items are tracked below.

## Owner decisions (binding)

- **F1 updater — opt-in modal (implemented).** Points, not paragraphs. Approve keeps prompts on; Deny *or dismiss* sets `neverAskAgain` (decline-by-default per F-Droid guidance). Re-enable in Settings; manual checks via the sidebar Check-for-updates icon. Nothing downloads unless Update is tapped.
- **Lite-only flavors.** Default `flutter build apk` builds lite with **no flavor flag**. `legacy-full` exists only on explicit request. Releases ≥ 0.7.5 ship lite only. Main codebase holds lite code; legacy code lives behind the legacy prefix; no lite/legacy `if`-checks in main code; flavor tags/placeholders removed.
- **Cancel vs skip.** Cancel = one-off tasks. Skip = recurring runs only. There is no "cancel series" — series end via pause/delete.
- **H6 + M3.** Inexact-alarm fallback goes through `TaskAlarmRescheduleJobService` (extend it, no new WorkManager dep). Prompt once for exact alarms on first scheduled task.
- **H5.** Simpler boot restore + 3 corrections: open the DB read-write (WAL needs it), split recurring (next slot) vs one-off (skip with reason), freshness window (due < 30 min ago still runs).

## Now

**Background resilience (phase 2 of the bigger-model plan; phase 1 shipped):**
- [ ] Per-turn checkpoint/resume (survive SIGKILL mid-run instead of restarting).
- [ ] Reaper — partly covered by heartbeat + foreground recovery; decide if a WorkManager periodic job is still wanted.
- [ ] `getHistoricalProcessExitReasons` on launch → log the kill reason into the task row.
- [ ] Battery/onboarding screens (exact alarm, exemption, OEM autostart deep links).
- [ ] Headless-browser policy (disable `browser` tool in headless by default?).

**Scheduler/native:**
- [x] H6 + M3 — JobScheduler fallback (`TaskExecutionJobService`, `scheduleJob` on both engines, receiver reroute on FGS-start failure, `cancelAlarm` tears down jobs; Dart routes when exact denied). CI-gated + needs device check.
- [x] H5 — boot-restore corrections (RW open, recurring grid-slot jump + persist, 30-min freshness run-now, skip-with-reason log rows, per-action reasons, manifest drops directBootAware/QUICKBOOT). CI-gated.
- [x] S2 — `QUERY_ALL_PACKAGES` dropped (launcher discovery covered by `<queries>`); `MANAGE_EXTERNAL_STORAGE` kept with manifest justification. Device check needed for chooser disambiguation.
- [x] C1 remainder — MIME allowlist (audio/video/image/text + pdf/json; caller `type` validated too) + shared `FileContainment.kt` used by open_file/installApk/**openPdf**. CI-gated.
- [x] `bringToFront` PI code + cancel (mirrors launch path). CI-gated.
- [x] `putExtraValue` divergence — unified (background engine now throws like foreground).
- [ ] Tool-edit parity with `computeEditTransition`.
- [ ] R8 verify, L1 residue.

**Shell leftovers:** fork-bomb multiline + `exec`-firewall exemption (done, pinned), `command -v` flag skip (done), bare `ifconfig promisc` (done). Remaining: none — shell list clear.

**Chat/LLM:** double-send latch (done: `_busy` sync gate + latch narrowed to `_turnInFlight`), first-backoff-zero (done: true 2^n, pinned), fingerprint content hash (done), `deleteConversation` invalidation (done), 4 `as` casts (done), `delay_seconds` bounds (done). Remaining: dispose-during-turn guard.

**Perf/dup:** P6–P10, D4/D8, D2 model-resolution half (key half done).

**Structural (deferrable):** R1 (shell-safety split), R2 (`executeTask`), R3 (chat screen), R4 (channel-per-file), R5 (tasks screen build); R6–R10 small.

## F-Droid checklist

- [x] S1 hardening (fail-closed SHA + native re-verify + anti-rollback).
- [x] F5 (pub-cache mutation removed), F6 (binaries untracked).
- [ ] F1 modal — implemented, needs on-device check.
- [ ] F2 `fastlane/metadata/`, F3 tag `v0.7.5`, F4 Flutter pin in `release.yml`, F7 metadata details (permissions justification, AntiFeatures: NonFreeNet + Tracking?).

## Queued milestones (specs, trimmed)

- **P6b browser rough edges:** kill PlatformView reparenting (Case 2 already selected: permanent slot, fixed offstage geometry, RepaintBoundary, pauseTimers offstage). Verify in profile mode.
- **P13.2 deterministic browser:** condition-waits replace fixed sleeps; ref freshness; act→verify loop; typed error taxonomy (`OK_VERIFIED`, `NOT_FOUND`, `STALE_SNAPSHOT`, …); evidence bundle on failure; self-check matrix suite.
- **P13.3 intent honesty:** per-action reliability tiers in `docs`; `DISPATCHED`/`NO_HANDLER`/`BLOCKED`/`UNKNOWN` outcome vocabulary; `canResolve` pre-flight everywhere; on-device action matrix per release.
- **P13.4 background profiling:** mine logs by failure class first; offline-at-alarm → reschedule (already the failure-transition contract); transport errors ≠ failure notifications; optional WiFi-only toggle.
- **P14.1 briefing chips**, **P14.2 read-aloud**, **P14.3 conversations tool** (`write_title` self-scope, two-phase `search`, `recall` by ref; no raw SQL exec).
- **Backlog:** safe file-edit tool, local semantic retrieval (FTS5 only if p95 > 200ms), stream-stall watchdog (partially covered by 120s inactivity).

## Moot — do not work on these

Deleted by the lite-only teardown: R2-H7, R2-M1, R2-M8, R2-D5, R2-D6 (and the a11y part of R2-P10).
