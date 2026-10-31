# Notifications — design (2026-10-31)

Status: **milestone 1 shipped 2026-10-31** (option A: while-app-running digests —
`UpdateNotifications.swift` core + `NotificationsCoordinator` + Settings → Updates tab;
milestone 2, the launchd agent, still open). Architecture advice from a codex advisory
session against this repo. **Gate 1 (signing/authorization) passed 2026-10-31** — evidence
below; gates 2–7 still open.

## Goal

Tell the user "N installed formulae/casks have newer versions" **without** requiring them to
open Brewery and press refresh; a notification click lands the user in the Outdated view.

## Constraints from the current build

- Bundle is **ad-hoc codesigned** (`Tools/make-app-bundle.sh:36`, `codesign -s -`):
  no Team ID, designated requirement is the per-build cdhash. Identity continuity across
  rebuilds is an open risk for both UNUserNotificationCenter and helper registration.
- Non-sandboxed, single-user, locally built, never distributed. Target macOS 26.
- `brew outdated` can trigger a full Homebrew self-update (compatibilities §73).
  `BrewRunner` sets `HOMEBREW_NO_AUTO_UPDATE=1` (`BrewRunner.swift:15`) but does **not**
  strip `HOMEBREW_FORCE_API_AUTO_UPDATE`, which Homebrew documents as overriding it.
- GUI already refreshes at launch and on focus regain (`ContentView.swift:83-87`), so the
  notification's real job is **discovery while the app is closed** plus routing.

## Options evaluated

| Option | Works while app is quit | Sleep behavior | Verdict |
|---|---|---|---|
| A. App-embedded scheduler (`NSBackgroundActivityScheduler`, not a repeating `Timer`) | no | deferrable, energy-aware | smallest change; ship first |
| B. LaunchAgent installed from Settings, same binary in headless mode | yes | `StartCalendarInterval` coalesces missed sleep runs into one catch-up after wake (Darwin 27 launchd manpage); `StartInterval` misses them; shutdown does not replay | target design |
| C. cron entry from Settings | yes | missed runs are skipped; Apple discourages programmatic crontab editing; no app integration | **rejected** — no advantage over B |

B registration, modern path: plist inside `Brewery.app/Contents/Library/LaunchAgents` with a
relative `BundleProgram`, registered via `SMAppService.agent(plistName:)` — Apple's sanctioned
replacement for writing into `~/Library/LaunchAgents`. Legacy fallback if `SMAppService` trips
on ad-hoc signing: write `~/Library/LaunchAgents/com.illusion.brewery.updates.plist` and
`launchctl bootstrap gui/<uid>`. No admin approval flow (that is LaunchDaemon-only), but the
user sees and can disable it under System Settings → Login Items & Extensions.

**Recommendation: B + A hybrid, staged.** Milestone 1 = A alone (GUI running only, clearly
labeled). Milestone 2 = the daily one-shot agent; the GUI reuses the same checker.

## Headless mode

- Early flag dispatch **before** the SwiftUI `@main` lifecycle:
  `Brewery --check-updates` → one check → digest → exit. Same bundled executable, launched
  from inside `Contents/MacOS` (keeps the bundle's notification identity; a separate helper
  does **not** inherit the app's notification permission — do not assume it does).
- Launchd labels do not determine notification attribution.
- Foundation-only submission may work headless; keep a run loop until the notification
  delivery callback completes (async submission + immediate exit drops the notification).
  Fall back to a minimal windowless AppKit lifecycle if needed.
- Click handling: `UNUserNotificationCenterDelegate` installed early; default action opens
  Brewery's Outdated section; must work cold-launch and into an already-running GUI.

## Scheduling & Homebrew safety

- Daily calendar run (e.g. 10:00 local), `ProcessType = Background`, no `KeepAlive`, no wake
  requests. Six-hour cadence only if the manifest cache policy is deliberately changed
  (manifest cache is 24 h / ~16 MB — a 6 h checker on that cache mostly repeats local work).
- Do **not** make `brew outdated` the background freshness mechanism (auto-update gotcha §73,
  and it cannot refresh tap checkouts either). Background check reuses the existing pipeline:
  `brew list --json --versions` + `brew info --json=v2 --installed` + manifest fetch +
  shared `OutdatedPolicy`.
- Strip `HOMEBREW_FORCE_API_AUTO_UPDATE` from the child environment (gap in `BrewRunner` today).
- LaunchAgent environment is not the interactive shell: explicit executable paths, bounded
  retries, process deadlines, discarded stdin.
- Concurrency: advisory lock on a dedicated persistent Brewery lock file (same inode, never
  deleted); serialize check → state reconcile → notification submit; GUI refresh participates.
  `PgrepBrewProbe` is advisory only. Never touch Homebrew's private locks. Failed/inconsistent
  check keeps the last good state.

## Notification content & dedup

- **One digest**, not per-package banners: "5 packages have newer versions — 3 formulae,
  2 casks. Open brewery to review." Max one interrupting digest per 24 h; pending bumps
  wait for the next eligible digest. No sound; suppress foreground banner while Brewery is
  frontmost.
- Dedup key: `(kind, qualified package name, target version)` — a *new* bump re-announces
  even when the total count is unchanged. Dismissed ≠ acknowledged; no re-ping on dismiss.
- Pinned packages: visible in GUI, excluded from notifications by default (current policy
  still shows newer versions for pinned rows — compatibilities §71).
- Self-updating/greedy casks: never announce `:latest`/unknown targets repeatedly; only
  concrete version pairs.
- State: versioned `update-notifications.json` under `~/Library/Application Support/brewery/`
  (announced pairs, pending pairs, last digest time, last success, metadata age). Follow the
  HistoryCache atomic-write pattern **except** its silent `try?` failure (`HistoryCache.swift:91`)
  is unacceptable here: a failed dedup write must suppress further notifications, not cause
  repeated banners.
- Housekeeping: stores use lowercase `brewery/` but `ManifestFetcher.swift:50` uses `Brewery/`
  — unify before adding a third store (breaks on case-sensitive volumes).

## Settings UI

Third tab **Updates**: notification enable + authorization status, background-check enable +
registration status, daily/six-hour choice, "Send test notification", last successful check,
metadata age. Notification permission and background-item registration are **separate**
permission states; surface both, and route denied states to System Settings (repeated
`requestAuthorization` does not re-prompt after denial).

## Signing decision — resolved for UNUserNotificationCenter (2026-10-31 probe)

Probe: standalone ad-hoc-signed `NotifyProbe.app` (bundle id `com.illusion.brewery.probe`,
LSUIElement, minimal `NSApplication` accessory lifecycle + `UNUserNotificationCenter`),
sources `.build/notify-probe/`, log `/tmp/brewery-notify-probe.log`.

Verified on this machine (macOS 26 / Darwin 27):
- `requestAuthorization` from an **ad-hoc-signed, non-sandboxed** bundle: prompt shown,
  `granted=true`, settings went `auth=0 → auth=2`, delivery `add err=none`, banner visible.
- **Grant survives rebuilds with different cdhashes**: three distinct binaries
  (`d1d687… → d62023… → e96aa0…`), each launching with `pre auth=2`, no re-prompt, delivery
  accepted. TN3127's per-build ad-hoc identity continuity did not bite for UN authorization
  on this OS.
- Click on the banner reached the app delegate:
  `didReceive ... action=com.apple.UNNotificationDefaultActionIdentifier` (warm app; cold-launch
  click routing not separately tested).
- **Direct exec works** (gate 2, 2026-10-31): `Contents/MacOS/NotifyProbe` run straight from a
  shell — no `open`, no LaunchServices launch — delivered and was clicked. Windowless AppKit
  (`activationPolicy = .accessory`) is sufficient lifecycle; the run loop waited for the
  delivery before exit. What is *not* yet tested is launchd itself starting that executable.

Consequence: milestone 1 needs **no new signing identity**. `SMAppService` registration under
ad-hoc signing remains an open risk (gate 3) — Apple DTS flagged ad-hoc there specifically.
A stable local identity is the fallback, not the plan.

## Verification gates (run before committing code)

1. **Signing gate — PASSED 2026-10-31** (see "Signing decision" above for evidence).
2. **Headless gate — PASSED (partial) 2026-10-31** — direct exec from terminal: delivery,
   no window, click routing warm. Launchd-started variant folds into gate 3.
3. **Registration gate** — `SMAppService` with ad-hoc signing; logout/login; user-disable state.
4. **Sleep gate** — sleep across the scheduled time; expect exactly one catch-up run.
5. **Concurrency gate** — GUI refresh + agent overlap → one digest; crash between submit and
   state write (exactly-once is not guaranteed — measure the duplicate blast radius).
6. **Data gate** — stale manifest/offline, tap lag, malformed JSON, pinned, greedy casks,
   state-write failure.
7. **Lifecycle gate** — `make-app-bundle.sh` deletes/recreates the bundle every build;
   test registered jobs across rebuilds; settle on one stable app location first.

## Open questions

- Tap-package freshness cannot be fixed by scheduling alone (latest known version comes from
  locally cached definitions — compatibilities §71). Accept tap lag in digests, or design an
  explicitly authorized metadata-update step later.

Docs consulted (via codex advisory): Apple TN3127, TN2206, UserNotifications authorization and
handling guides, SMAppService migration guide, managing background processes (AppKit),
launchd Scheduling Timed Jobs + local Darwin 27 manpages, docs.brew.sh Manpage/Querying-Brew.
