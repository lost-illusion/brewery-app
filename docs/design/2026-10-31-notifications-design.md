# Notifications — design (2026-10-31)

Status: **milestones 1–2 shipped 2026-10-31** (option A while-app-running digests +
option B launchd agent: `UpdateNotifications.swift` core + `NotificationsCoordinator` +
Settings → Updates tab + `Main.swift` headless entry + `UpdateCheckLock`). Transport
decision changed same day: the SMAppService/BundleProgram submission **worked first, then
failed unrepeatably** under ad-hoc signing (dyld SIGKILL "Launch Constraint Violation" at
exec; submission degraded to `spawn failed` / exit 78 while SMAppService status still read
"registered"). The shipped design is now the doc's legacy fallback: an app-managed plain
LaunchAgent in `~/Library/LaunchAgents` with an absolute `ProgramArguments` path, reloaded
at GUI launch. Verified end to end: bootstrap + kickstart on the freshly rebuilt binary →
headless check runs, `last exit code = 0`. Remaining open: gate 4 (sleep catch-up), gate 5's
crash-window tail, gate 6's offline sub-case, and login-time auto-load of the LaunchAgent
(legacy behavior, expected — untested).
Architecture advice from a codex advisory session against this repo. **Gate 1
(signing/authorization) passed 2026-10-31** — evidence below.

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

B registration — modern path tried, legacy path shipped. Tried first: plist inside
`Brewery.app/Contents/Library/LaunchAgents` with a relative `BundleProgram`, registered via
`SMAppService.agent(plistName:)`. It registered and fired (gate-3 evidence below) but began
killing the spawned binary after several rebuild/re-sign cycles — dyld SIGKILL, "Namespace
CODESIGNING, Code 4, Launch Constraint Violation" — and the submission wedged into
`spawn failed` (exit 78 EX_CONFIG) while SMAppService status kept reading "registered".
Shipped instead: the fallback the doc always reserved — `NotificationsCoordinator.writeAgent`
writes `~/Library/LaunchAgents/com.illusion.brewery.updates.plist` (absolute
`ProgramArguments` = current executable + `--check-updates`) and runs
`launchctl bootout … ; bootstrap gui/<uid> <plist>`; GUI launch re-asserts it whenever the
plist exists, so rebuilds and app moves self-heal. Legacy agents load at every login by
launchd itself (expected, untested). No admin approval flow (LaunchDaemon-only); background
items appear under System Settings → Login Items & Extensions for user-level disabling.

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

Consequence: milestone 1 needs **no new signing identity**.

- **`SMAppService` registration works under ad-hoc signing** (gate 3, 2026-10-31): probe
  bundle with `Contents/Library/LaunchAgents/com.illusion.brewery.probe.updates.plist`
  (`BundleProgram: Contents/MacOS/NotifyProbe`, `StartInterval 60`) → `register()` succeeded,
  `status = registered` (no `requiresApproval`, no user consent UI), and launchd fired the
  binary twice at exact 60 s intervals; the fired process resolved `Bundle.main.bundleIdentifier`
  normally, so notification identity is retained. DTS's ad-hoc warning did not bite here.
  A launchd-started process is identifiable by `XPC_SERVICE_NAME == <agent label>`
  (a tool-shell may inherit `XPC_SERVICE_NAME=0` — match exactly, don't just test presence).
  API gotcha: this SDK renamed `SMAppService.Status.registered` to `.enabled` and bridged
  the C names lowerCamelCase — the cases are `.notRegistered` / `.enabled` /
  `.requiresApproval` (the old `.registered` is gone; compiler suggestions may show the
  obsoleted `NotRegistered`, which does not compile).

## Verification gates (run before committing code)

1. **Signing gate — PASSED 2026-10-31** (see "Signing decision" above for evidence).
2. **Headless gate — PASSED 2026-10-31** — direct exec from terminal: delivery, no window,
   click routing warm; launchd-started delivery proven by the gate 3 probe (gate-3 fired
   process posted visible banners). On the shipped bundle the kickstart runs evaluated the
   digest but announced nothing — zero eligible pairs on this machine right now, so a real
   digest from the shipped agent waits for a genuine pending update.
3. **Registration gate — PASSED (core) 2026-10-31, transport since changed** — probe evidence
   above, then live on the shipped bundle: Settings toggle → `launchctl print` shows the job,
   `kickstart` ran the real agent (headless log, state `lastCheckAt` advanced, `last exit code = 0`).
   That SMAppService submission later wedged (see option B above: codesign kill → `spawn failed`);
   the plain-LaunchAgent replacement re-registered via the app's own `writeAgent` + GUI-launch
   re-assert and kickstart fired again, `last exit code = 0`. Login-time auto-load of the legacy
   agent and user-disable state still untested.
4. **Sleep gate** — sleep across the scheduled time; expect exactly one catch-up run.
5. **Concurrency gate — PASSED (core) 2026-10-31** — two headless processes launched
   simultaneously: one logged "skipped: another brewery check holds the lock", the other
   completed ("check done"). Same flock guards the GUI's `evaluate()`. Same-day follow-up: the
   headless entry's *outer* lock was removed — flock blocks per-open-file-description, so the
   outer+inner pair had been self-blocking and silently no-op'ing every headless digest check.
   Still open: the crash window between UN post and state write (exactly-once is not
   guaranteed — measure the duplicate blast radius).
6. **Data gate — PASSED (core) 2026-10-31** — real state file replaced with garbage, agent
   kicked: survived (exit 0), did not clobber the file, and the new `evaluateReporting` logged
   "notifications state is unreadable — announcements stay off until it is fixed"; restoring the
   file produced a normal run. Corrupt→nil unit tests already covered. Open: offline / stale
   manifest behavior of the agent itself.
7. **Lifecycle gate — PASSED (core) 2026-10-31** — `make-app-bundle.sh` deletes/recreates/
   re-signs the bundle every build. Under SMAppService this initially survived but eventually
   wedged the job (the codesign findings above are that story). Under the shipped plain-LaunchAgent
   transport it is designed away: GUI launch rewrites the plist with the current executable path
   and reloads it, verified — after a rebuild, the app-submitted job fired with `last exit
   code = 0`; app relocation is covered the same way (the plist is rewritten with the new path).

## Open questions

- Tap-package freshness cannot be fixed by scheduling alone (latest known version comes from
  locally cached definitions — compatibilities §71). Accept tap lag in digests, or design an
  explicitly authorized metadata-update step later.

Docs consulted (via codex advisory): Apple TN3127, TN2206, UserNotifications authorization and
handling guides, SMAppService migration guide, managing background processes (AppKit),
launchd Scheduling Timed Jobs + local Darwin 27 manpages, docs.brew.sh Manpage/Querying-Brew.
