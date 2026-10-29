# brewery — Slice 1 design: Inventory view

Date: 2026-10-29. Status: draft for approval. Companion research: `docs/compatibilities.md` (cited as §N below; Homebrew 7.0.11 verified).

## Intent

The app is a "brew store": a SwiftUI macOS app to view, track, search, install, uninstall, and update Homebrew packages, with a later "watch" feature that notifies when updates appear for installed packages.

Slice 1 is the **read-only inventory view** — the app's "library": everything installed, its state, and its badges. It is the first slice because its data path is fully specced (compatibilities §1, §41–49), it mutates nothing, and every later slice (search, install, upgrade, watch) hangs off its data layer and process runner.

## Goals (this slice)

1. Show every installed formula and cask with versions and state.
2. Sidebar badges + counts: outdated, pinned, deprecated/disabled.
3. Per-package detail pane (read-only).
4. A hardened brew process runner + defensive JSON decoding that every later slice reuses.
5. Local filter over the loaded inventory (text filter, kind filter, sort). This is **not** catalog search.
6. Refresh: manual (⌘R / toolbar) and on-window-focus when the snapshot is stale (default threshold: 5 minutes — my call).

## Non-goals (later slices, listed so this one stays small)

- Catalog search (`brew search` has no JSON — §2; needs text parsing).
- Any mutating action: install/uninstall/upgrade/pin/link (confirmation UI work — §Mutating).
- Services panel, tap manager, Brewfile features.
- Watch/notifications. This slice only persists a snapshot the watch slice will diff.

## Anti-goals

- Never shell out through a shell string — `Process` with an args array only.
- Never link Homebrew Ruby internals (§ key architectural fact).
- Never offer removed commands/flags: `brew cask`, `brew switch`, `--purge`, `bundle restore` (§ Gaps).
- Never let the app trigger brew's self-update: every invocation sets `HOMEBREW_NO_AUTO_UPDATE=1` (§3 auto-update interference).
- Never hide the untrusted-tap gap silently (see Merge rules — real case found on this machine).
- Not a Mac App Store sandboxed build: a sandbox blocks spawning `brew`. Distribution outside MAS is assumed (my call).

## Stack (my call, since "just SwiftUI" was the brief)

- Swift + SwiftUI, single target, macOS deployment target = one major behind the current one (built here on macOS 27 / arm64; target macOS 26). No AppKit except where SwiftUI can't reach.
- `NavigationSplitView` three-column layout. Window-based app; no menu-bar extra in this slice.
- Settings: brew binary path override, refresh staleness. UserDefaults is fine.

## Data layer

### Runner contract (reused by all slices)

- Locate brew: probe `/opt/homebrew/bin/brew`, then `/usr/local/bin/brew`, then `PATH`; user override in settings. If none found → first-run setup sheet.
- Fixed environment on every spawn: `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_COLOR=1`, `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_ANALYTICS=1`. Explicitly **remove** inherited `HOMEBREW_DEVELOPER` (§13 — it turns warnings into errors), `HOMEBREW_VERBOSE`, `HOMEBREW_DEBUG`.
- Failure = non-zero exit (§13); capture stdout+stderr separately, strip ANSI as a backstop.
- `brew list --json` requires `jq` on PATH (§1 gotcha; `/usr/bin/jq` present on this machine — macOS ships `/usr/bin/jq`, so this is a rare fallback). Detect its absence at startup and fall back to parsing plain-text `brew list --versions` (line format verified: `ace 8.0.8`), which keeps untrusted-tap rows and pinned display — the anti-goal is honored even degraded. Banner notes degraded mode. (My call.)

### Commands (all read-only, all timed on this machine 2026-10-29)

| Call | Time (155 packages, cold) | Role |
|---|---|---|
| `brew list --json --versions` | ~0.3 s | fast first paint: names + installed/linked/pinned versions |
| `brew info --json=v2 --installed` | ~0.7 s | the rich model: descriptions, tap, outdated/pinned/deprecated flags, bottle, deps, install time |

Run both concurrently on refresh. Paint rows from `list` immediately, merge `info` in when it lands.

**Concurrency with brew outside the app** (my call): the runner keeps a single-flight queue app-side. Auto-refresh (focus-triggered) is *deferred* while an external brew is detected (`pgrep -x brew`, cheap, read-only) — the routine case is the user mid-`brew install` in Terminal while the app regains focus. Manual refresh always runs; if brew fails on lock contention, the banner shows brew's own stderr (fail-fast text, §13) plus a "brew is busy" hint, and auto-refresh backs off 60 s. `HOMEBREW_LOCK_CONTEXT` is left for debug logging only, not the fixed env.

`brew outdated --json=v2` is **not** needed for badges: pinned/deprecated come from info JSON booleans (§41/§45), and `isOutdated` is GUI-computed against the app-fetched manifest (Freshness decisions). Cross-check the GUI computation against `brew outdated --json=v2` before the upgrade slice depends on it.

### Model (`BrewItem`)

`kind` (formula/cask) · `name`/`token` · `fullName` · `tap` · `installedVersions[]` · `linkedVersion?` · `optlinkedVersion?` · `pinnedVersion?` · `latestVersion` (from the app-fetched API manifest — see Freshness decisions; info JSON's `versions.stable` / cask `version` only as offline fallback) · `isOutdated` (GUI-computed: manifest latest vs installed, per the greedy toggle) · `isPinned` · `isDeprecated` + reason/date · `isDisabled` · `desc` · `homepage` · `installedAt` (formula `installed[0].time`; cask `installed_time`) · `kegOnly`+reason · `autoUpdates` (cask).

Casks differ structurally from formulae — `installed` is a version string, not an array; decode with separate codables (§45).

### Merge rules (verified against live JSON)

- Formulae match on `name`; casks match on **`token`** — `list --json --versions` cask items use `token`, not `name` (observed; compatibilities §47 corrected).
- `list` has entries `info --installed` omits: installed `ralphex` (152 in list vs 151 in info) is from untrusted tap `umputun/apps`, which brew refuses to read info for (§7 trust model). Render such rows from list data only, dimmed, with a "source unavailable — tap not trusted" affordance that explains the gap. Do not drop the row.
- Reverse case (in info, not in list) — treat as API/list skew: show, flag as suspicious in a debug hint.

### Decoding posture

§ Gaps: no versioned JSON schema. Ignore unknown keys; expect nulls (`versions.head`, `linked_keg`, `pinned_version` all null in practice); treat a failed decode as "degraded row with raw versions from list", never a crash. Cache raw JSON + timestamp in Application Support — this is also the snapshot the future watch slice diffs.

## View layout

- **Sidebar**: Library sections with live counts: All · Formulae · Casks · Outdated · Pinned · Deprecated/Disabled. Footer: "Updated HH:MM" + refresh button. Slice-1 counts on this machine: 152 formulae / 3 casks, 0 outdated, 0 pinned, 1 deprecated.
- **Content column**: table rows — kind glyph, name, one-line desc, `installed → latest` (arrow + accent when outdated), trailing badges (pin, deprecated). Local text filter field; kind/sort menu. Row count here (155) is trivial; no virtualization worry.
- **Detail pane** (trailing): versions, tap, linked/keg-only state, installed-at, bottle tag + sha256 from `bottle.files` (§41, e.g. `arm64_golden_gate`), dependency count + names (read-only from `dependencies`; no graph view yet), caveats, homepage button (browser launch is an accepted side effect — §17 `home`), deprecated/disabled banner with reason.
- **States**: loading (skeleton, list-rows first) · empty (fresh machine → "nothing installed" with pointer to next slice's install flow) · brew-not-found (setup sheet) · jq-missing (degraded mode: plain-text `list --versions` fallback, banner) · command failure (error banner with captured stderr).

## Freshness decisions (owner calls, 2026-10-29)

1. **Version freshness: the app fetches the public API itself.** brew's query commands never refetch their cached API manifest (verified §3), so `latestVersion` / `isOutdated` are computed against a manifest the app downloads read-only from formulae.brew.sh — the same package manifest brew consumes (`packages.<bottle-tag>.jws.json`, observed §23) — on its own staleness threshold (default 24 h, fetched lazily on refresh — my call), never on every inventory refresh. Core formulae/casks get fresh latest data; tap and untrusted packages have no manifest entry → `latestVersion` nil, rendered "—", never "up to date". Offline: serve the last cached manifest with a footer "Version data as of HH:MM". `brew update` is never run by this slice. JWS payload parsing/verification left to the builder.
2. **Outdated badge: brew-default semantics with a greedy Settings toggle (default off).** Default reproduces `brew outdated`: `:latest` / `auto_updates` casks are not counted. Toggle on → those casks are flagged "updatable (self-updating)" without claiming a version. Sidebar counts, row arrows, and the watch slice's baseline all inherit the toggle.

## Left to the builder

- Exact deployment-target availability gating.
- Where the detail pane is rendered (inspector column vs row push) as long as all listed fields appear.
- Iconography/typography choices.
- Snapshot cache format (raw JSON passthrough vs decoded model) — must keep raw bytes for the watch-slice diff.

## Hook points kept for later slices

- The runner is the same one mutating slices will use (they add `-y` ask-mode suppression — §4 — and confirmation UI).
- `BrewItem` already carries everything the upgrade slice needs to build an "updates" list.
- Persisted snapshot + timestamp is the watch slice's diff baseline.
- Detail pane reserves the trailing-edge action slot where Install/Update buttons land later.
