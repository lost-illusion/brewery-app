# Install pane — design (2026-11-02)

Status: **phase 1 shipped 2026-11-02**, same day extended to **external taps**
(§External taps). Search pane: `PackageSearch.swift` core + `InstallList` /
`InstallPreview` views + `.install` sidebar section. Install itself reuses the
existing `InventoryModel.installItem` (already proven by the Taps pane).
Phase 2 (streaming install progress) shipped **2026-11-10** — see §Streaming progress.

## Goal

Let the user find and install Homebrew packages that are **not installed yet** —
formulae and casks — from a dedicated sidebar pane, without ever shelling out to a
search parser.

## Constraints from the current build

- The core manifest (`packages.<bottle_tag>.jws.json`) is **already fetched every
  refresh** (`InventoryModel.performRefresh`) and holds every core formula
  name + desc + stable version and every cask token + version + display name
  (compat §23). Third-party tap packages are **not** in it.
- `brew search` has **no JSON** in 7.0.11 and its GitHub-API backing can be
  rate-limited (compat §3) — parsing its text would be the weakest search path.
- `InventoryModel.installItem(qualified:)` already runs `brew install -y <tap>/<name>`
  (ask-mode suppression, compat §77), serialized against every other brew call
  via `runTapAction`, with the busy-probe guard and a full inventory reload after.
  The Taps pane uses it (`TapDetail.entryRow` / `previewBody`).
- `fetchPreview` + `InventoryMerger.preview` answer `brew info --json=v2` for
  not-installed packages — the preview the Taps pane already renders.
- `BrewRunner` was one-shot (buffers all output until exit) at design time; phase
  2 added `runStreaming` alongside it — the buffered `run` stays for the JSON
  commands (list/info/tap-info/trust), which never need progress.

## Decision: search source

| Option | Latency | Coverage | Verdict |
|---|---|---|---|
| A. Local match over the fetched manifest | instant, offline | core formulae + casks only | **shipped** — zero new commands, zero rate limits |
| B. Parse `brew search` text | ~1 s per keystroke, hits the GitHub API | all taps | **rejected** (compat §3) — tap coverage was added from the already-fetched tap-info JSON instead (§External taps) |
| C. formulae.brew.sh public JSON endpoints | network per query | core only | **rejected** — same coverage as A, more moving parts |

### External taps (same-day addition)

**Why the manifest alone excludes them:** the manifest is core/cask-only by
construction — tap packages have no manifest entry at all (compat §23, live-verified:
`umputun/apps/*` formulae absent). `brew search` was rejected as a source (no JSON,
rate-limited), so at first the pane simply stated the gap and pointed at the Taps pane.

The fix needed no new command: **`brew tap-info --installed --json` — which the Taps
pane already fetches — carries every installed tap's `formula_names` and
`cask_tokens`** (compat §7). `searchCatalog` now takes `taps:` and feeds those names
through the same matcher:

- only taps with `installed == true` contribute — virtual API taps
  (`homebrew/core`/`homebrew/cask` reported installed:false) would restate the
  manifest without desc/version;
- names already offered by the manifest are deduped out (wins: desc + latest
  version; also covers a core tap checked out on disk);
- tap entries carry names only — no desc, no version — the row shows the source
  tap as its subtitle;
- entering the Install pane triggers `loadTaps()` (single flight, cached); without
  jq, `brew tap` yields names only and the empty state says tap search needs jq;
- trust rules follow TapDetail: untrusted-tap previews surface brew's refusal
  verbatim with an inline Trust button; a fully-qualified install auto-trusts the
  item (§22), and the trust store drives the header chip.

## Decision: pane vs. quick-search overlay

A ⌘K overlay is lighter but has no natural home for a multi-step install flow
(catalog list → preview → install → feedback banner). A sidebar section fits the
existing three-column shape and reads as the natural pair **Installed / Install**.
Shipped as `.install`, sidebar slot right after Installed.

## Architecture

### Core (`PackageSearch.swift`)

`searchCatalog(manifest:installed:taps:kind:query:) -> [CatalogSearchResult]` — pure,
no brew calls (same posture as `matchesQuery`). `CatalogSearchResult.id` is the
**qualified** `tap/name` — the exact string `installItem` accepts; a fully-qualified
install also auto-trusts its item (§22), which core packages never need but costs
nothing. `installedItemID` cross-refs by name+kind against the inventory (any tap —
a tap package sharing a core name counts and gets the row's installed affordance).

Scoring (first match wins; ties sort by name):

| Score | Rule |
|---|---|
| 1000 / 990 | exact name / display name |
| 900 / 880 | name / display-name prefix |
| 800 / 780 | token prefix (name split on `-`/`_`/space) |
| 700 / 650 | name / display-name substring |
| 600 / 550 | name / display-name subsequence (typo-tolerant fuzzy) |
| 400 | description substring |

No match → excluded. Case-insensitive throughout.

### UI

- `InstallList` (content column): `.searchable`, kind segment (All | Formulae | Casks,
  same toolbar shape as the Installed pane), rows with kind icon / name / installed
  chip / latest version / desc; cap 200 rows with a "narrow the query" note;
  carries the `tapAction` banner so install start/failure is visible in the list too.
- `InstallPreview` (detail column): mirrors the Taps preview — `fetchPreview` on
  selection (cached per qualified name, re-fetched after any finished mutation),
  DeprecationNotice banner (deprecated installable / disabled blocked), facts grid,
  prominent **Install** button (same no-extra-alert posture as `TapDetail` — the
  click *is* the confirmation; the help text names the exact brew command).
- Selecting an **installed** result hands off to the Installed pane with that row's
  detail open — the Chart precedent (`ContentView`'s topInstalls handoff, same shape).

## Streaming progress (phase 2, shipped 2026-11-10)

Live `==>` output + Cancel for every long mutation (install, uninstall, tap/pin/trust
actions, upgrade, §27 switch steps). Compat gotchas (grandchild-held pipes, poll
`POLLIN|POLLHUP`, thread placement, SIGINT posture): compat §28 — read that before
touching the runner.

- **Core** (`BreweryCore/Streaming.swift`): `BrewCancellationToken` (one-shot, any
  thread); `BrewLineSplitter` splits `\n`, `\r\n` as one, and bare `\r` (brew's bar
  rewrites) at byte level so a chunk cut never splits a UTF-8 character;
  `appendProgressLines` folds consecutive bar frames to the latest and caps the
  buffer at 300 lines.
- **Runner** (`BrewRunner.runStreaming`): declared as a `CommandRunning` *requirement*
  with a buffered extension default — extension-only methods don't dispatch through
  existentials, and the first cut of this feature shipped exactly that bug (fakes'
  overrides were shadows). Watchdog polls `cancellation` every 60 ms and calls
  `interrupt()` (SIGINT → brew exit 130); the pipe reader is one poll loop on the
  global queue that ends on process exit, not EOF (compat §28). Full stdout/stderr
  still captured — failure banners unchanged.
- **Model** (`InventoryModel.withActionProgress`): per-line `AsyncStream` into
  `actionProgress` (MainActor); `progressActionLabel` drives the sheet;
  `cancelAction()` feeds the token. Cancel reports `.failed` with
  "Cancelled — brew was interrupted; partial work may remain — inventory reloaded"
  (no new enum case — every existing banner switch keeps working) and reloads
  taps + inventory, unlike a brew refusal. Multi-command actions (upgrade chain,
  switch steps) share one continuous progress buffer.
- **UI** (`ActionProgressSheet`): headline = action label, monospaced line tail with
  auto-scroll, Cancel button (Esc). Presented only after an 800 ms debounce —
  pin/trust finish in tens of ms and a blinking sheet is worse than none; the tail
  stays readable after success, only the sheet closes.

## Alias / rename recall (phase 3, shipped 2026-11-12)

Manifest alias keys are now decoded (`aliases`, `oldnames`, cask `names`, the
rename + tap-migration maps — payload shapes and gotchas in compat §29) and fed
into `searchCatalog` as per-row alias terms. A term scores its tier **−100**, so
direct name hits always outrank aliases and never show a hint; only otherwise-
unmatched rows surface, captioned `aka X` / `renamed from X` / `moved from X`
(`CatalogSearchResult.matchHint`, shown in the row subtitle and preview).
Migrations attach the old identifier to the destination row of the opposite
kind when the manifest lists it; same-name and unlisted destinations add nothing.

## Deferred (phase 3+)
- Manifest `desc` is formula-only; cask rows show the display name instead. A
  future manifest decode extension could add cask desc.
- Tap entries lack desc/version too (tap-info doesn't carry them); richer tap
  search would need a per-tap index the app doesn't have.
