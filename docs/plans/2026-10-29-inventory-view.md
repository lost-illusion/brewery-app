# brewery Slice 1 — Inventory View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Sub-agents dispatched for this plan must not spawn further sub-agents (project rule in `AGENTS.md`).

**Goal:** A read-only SwiftUI macOS app listing every installed Homebrew formula and cask with state badges, sidebar sections, a detail pane, and a hardened brew data layer.

**Architecture:** SwiftPM package with a testable `BreweryCore` library (process runner, JSON decoders, merger, API manifest, outdated policy, snapshot store, observable inventory model) and a thin `BreweryApp` SwiftUI executable that only renders core state. All brew access goes through one `CommandRunning` seam; "latest version" data comes from the app's own read-only fetch of brew's public package manifest, never from `brew update`.

**Tech Stack:** Swift 6.4 (toolchain verified on this machine), SwiftPM, SwiftUI, Swift Testing (`import Testing`), no third-party dependencies.

**Spec:** `docs/design/2026-10-29-inventory-view-design.md` (read it with this plan; research values come from `docs/compatibilities.md`, cited as §N).

## Global Constraints

- `swift-tools-version: 6.4`, platforms `.macOS(.v26)`, Swift 6 language mode. No third-party dependencies.
- Tests are Swift Testing (`@Test`, `#expect`), run via `swift test`.
- Every brew spawn: `Process` with an args array (never a shell string), env = filtered parent env plus `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_COLOR=1`, `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_ANALYTICS=1`, with `HOMEBREW_DEVELOPER`, `HOMEBREW_VERBOSE`, `HOMEBREW_DEBUG` explicitly removed (§13, spec Runner contract).
- This slice issues only read-only brew commands: `list --json --versions`, `info --json=v2 --installed`, `list --versions` (text fallback). Mutating commands are forbidden (§Mutating).
- Manifest endpoint: `https://formulae.brew.sh/api/internal/packages.<bottle_tag>.jws.json` (verified 200; §23 note). Manifest staleness threshold: 86_400 s, fetched lazily on refresh. JWS signature verification is skipped — HTTPS transport integrity is this plan's call.
- Outdated semantics: brew-default (casks with `auto_updates` or `:latest` not counted); greedy behavior behind a Settings toggle, default OFF (owner decision, spec Freshness decisions #2).
- Tap-only packages (no manifest entry) render latest version as "—", never "up to date" (owner decision, spec Freshness decisions #1).
- App runs as a plain (non-sandboxed) SwiftPM executable; `swift run BreweryApp` is the run command.
- Commit after every task.

## Review Focus

Failure modes the spec implies but no single task's happy-path test exercises — each is pinned by a named test in the owning task:

1. **JSON schema drift**: unknown keys appear or optional fields go null → decode must succeed with nil values, never crash (Task 3, Task 4 adversarial fixtures).
2. **Untrusted-tap rows**: `list` shows a package `info --installed` refuses (`ralphex` case) → row renders from list data, `listOnly` state, explanation shown, row never dropped (Task 6).
3. **Cask identity**: `list --json --versions` casks key on `token`, not `name` → merge must key casks on token (Task 3, Task 6).
4. **External brew collision**: user runs `brew` in Terminal while focus-refresh fires → focus refresh defers; manual refresh surfaces brew's own error text (Task 9).
5. **Tap packages have no manifest entry**: latest must render "—" and the outdated state `unknown`, not a false "up to date" (Task 8).

## File Structure

```
Package.swift
Sources/BreweryCore/
  BrewItem.swift             model + SourceState
  BrewDiscovery.swift        brew binary location
  BrewRunner.swift           CommandRunning, BrewResult, fixed env
  ListJSON.swift             list --json --versions decodable
  InfoJSON.swift             info --json=v2 --installed decodable
  TextList.swift             plain-text list --versions fallback
  InventoryMerger.swift      list ⊕ info → [BrewItem]
  Manifest.swift             PackageManifest, ManifestFetcher, HTTPFetching
  OutdatedPolicy.swift       OutdatedState + pure computation
  SnapshotStore.swift        raw JSON + timestamp cache
  InventoryModel.swift       @Observable orchestrator, settings, probes
  InventorySections.swift    pure sidebar filtering/counting
Sources/BreweryApp/
  BreweryApp.swift           @main App + Settings scene
  ContentView.swift          NavigationSplitView assembly
  Sidebar.swift              sections, counts, footer
  PackageList.swift          rows, local filter, sort
  PackageDetail.swift        detail pane
Tests/BreweryCoreTests/
  Fixtures/                  trimmed REAL JSON from this machine + adversarial variants
  <mirror test files per source file>
```

---

### Task 1: Package scaffold, `BrewItem`, real fixtures

**Files:**
- Create: `Package.swift`, `Sources/BreweryCore/BrewItem.swift`, `Sources/BreweryApp/BreweryApp.swift` (empty-shell App), `Tests/BreweryCoreTests/BrewItemTests.swift`, `Tests/BreweryCoreTests/Fixtures/` (see Step 4)

**Interfaces:**
- Consumes: nothing.
- Produces: `BrewItem` used by Tasks 6–10:

```swift
public struct BrewItem: Identifiable, Hashable {
    public enum Kind: String { case formula, cask }
    public enum SourceState: Equatable { case complete, listOnly(reason: String), infoOnly }
    public let id: String              // fullName (formula) or token (cask)
    public let kind: Kind
    public let name: String            // formula name / cask token
    public let fullName: String
    public let tap: String?
    public let installedVersions: [String]
    public let linkedVersion: String?
    public let optlinkedVersion: String?
    public let pinnedVersion: String?
    public var latestVersion: String?  // filled by Task 8 logic
    public var outdated: OutdatedState? // filled by Task 8 logic
    public let isPinned: Bool
    public let isDeprecated: Bool
    public let deprecationReason: String?
    public let isDisabled: Bool
    public let disabledReason: String?
    public let desc: String?
    public let homepage: String?
    public let installedAt: Date?
    public let kegOnly: Bool
    public let autoUpdates: Bool       // false for formulae
    public let dependencies: [String]
    public let sourceState: SourceState
}
```

- [ ] **Step 1: Create `Package.swift`** — `swift-tools-version: 6.4`; products `BreweryCore` (library), `BreweryApp` (executable, depends on `BreweryCore`); target `BreweryCoreTests` tests `BreweryCore`; platforms `.macOS(.v26)`. Also create `Sources/BreweryApp/BreweryApp.swift` as `@main struct BreweryApp: App { var body: some Scene { WindowGroup { Text("brewery") } } }`.
- [ ] **Step 2: Write failing `BrewItemTests.swift`** — `test_brewItem_minimal_roundTrip`: build a `BrewItem` with only required fields (nil optionals, `sourceState: .complete`), encode with `JSONEncoder`, decode, `#expect(decoded == original)`.
- [ ] **Step 3: Run `swift test`** — expect FAIL (module does not compile / type missing).
- [ ] **Step 4: Implement `BrewItem.swift`** with the exact signature above; run `swift test` — expect PASS. Run `swift build` — expect both targets build.
- [ ] **Step 5: Extract real fixtures** into `Tests/BreweryCoreTests/Fixtures/` (commands are read-only, allowed by `AGENTS.md`):

```bash
cd Tests/BreweryCoreTests/Fixtures
HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew list --json --versions > list-real.json
HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew info --json=v2 --installed > info-real.json
HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew list --versions > text-list-real.txt
```

Then trim with `jq`: `list-real.json` keeps `.formulae[]` where `.name` ∈ `["ace","ralphex"]` plus all `.casks` → `list.json` (ralphex MUST stay — it is the Task 6 fixture). `info-real.json` keeps `.formulae[]` where `.name` ∈ `["ace"]` plus all `.casks` → `info.json`. Build `list-adversarial.json` from `list.json` adding one unknown key per item (`"brand_new_field": 1`) and `"linked_version": null`. Keep fixtures under 100 KB each.
- [ ] **Step 6: Commit** `git add Package.swift Sources Tests && git commit -m "feat: swift package scaffold, BrewItem model, real JSON fixtures"`.

---

### Task 2: Brew discovery and runner

**Files:**
- Create: `Sources/BreweryCore/BrewDiscovery.swift`, `Sources/BreweryCore/BrewRunner.swift`, `Tests/BreweryCoreTests/BrewRunnerTests.swift`

**Interfaces:**
- Consumes: Task 1 package only.
- Produces (used by Tasks 9–10):

```swift
public struct BrewResult: Sendable { public let exitCode: Int32; public let stdout: Data; public let stderr: Data }
public protocol CommandRunning: Sendable { func run(_ args: [String]) async throws -> BrewResult }
public struct BrewRunner: CommandRunning {
    public init(brewURL: URL, extraEnv: [String: String] = [:])
    public func run(_ args: [String]) async throws -> BrewResult
}
public func discoverBrew(searchPaths: [String], pathOverride: String?) -> URL?
// production call: discoverBrew(searchPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], pathOverride: settings.brewPathOverride)
```

- [ ] **Step 1: Write failing `BrewRunnerTests.swift`** — four tests:
  - `test_discoverBrew_findsFirstExecutableAndPrefersOverride`: temp dir tree with fake executables at both search paths; expect first hit; expect `pathOverride` wins; expect nil when none exist.
  - `test_discoverBrew_rejectsNonExecutable`: file exists but is not executable → skipped.
  - `test_run_passesArgsAndCapturesStreams`: fixture script `fake-brew.sh` echoes args to stdout and a fixed line to stderr and exits 0; assert both `Data` contents and `exitCode == 0`.
  - `test_run_exitCodeAndFailure`: script exits 1; assert `exitCode == 1` and stderr captured (no thrown error — exit codes are data, §13).
- [ ] **Step 2: Run `swift test`** — expect FAIL (types missing).
- [ ] **Step 3: Implement both files.** `BrewRunner.run`: `Process` at `brewURL`, `arguments = args`, environment = `ProcessInfo.processInfo.environment` minus `HOMEBREW_DEVELOPER`/`HOMEBREW_VERBOSE`/`HOMEBREW_DEBUG`, plus the four fixed vars from Global Constraints, plus `extraEnv`; pipes for stdout/stderr; no shell. Add a fifth test `test_run_envHygiene` (write it before implementing): `fake-brew.sh` prints `DEV=${HOMEBREW_DEVELOPER-UNSET} AU=$HOMEBREW_NO_AUTO_UPDATE` — expect `DEV=UNSET AU=1` even when the test process has `HOMEBREW_DEVELOPER=1` in its environment (set via `extraEnv` deliberately? No — set it on the runner's parent by exporting inside the fixture's call context is not possible; instead pass it via `extraEnv` on a runner variant and assert the fixed filter removes it).
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: brew discovery + hardened process runner with env hygiene"`.

---

### Task 3: `list --json --versions` decoding

**Files:**
- Create: `Sources/BreweryCore/ListJSON.swift`, `Tests/BreweryCoreTests/ListJSONTests.swift`

**Interfaces:**
- Consumes: `Fixtures/list.json`, `Fixtures/list-adversarial.json` (Task 1).
- Produces (Task 6 consumes):

```swift
public struct ListSnapshot: Codable {
    public struct FormulaItem: Codable { public let name: String; public let versions: [String]
        public let linkedVersion: String?; public let optlinkedVersion: String?; public let pinnedVersion: String? }
    public struct CaskItem: Codable { public let token: String; public let versions: [String]
        public let pinnedVersion: String? }   // token, NOT name — verified §47
    public let formulae: [FormulaItem]; public let casks: [CaskItem]
    public static func decode(_ data: Data) throws -> ListSnapshot
}
```

- [ ] **Step 1: Write failing `ListJSONTests.swift`** — `test_decode_realFixture` (ace present with `linkedVersion == "8.0.8"`; all 3 casks decode with non-nil `token` — Review Focus 3), `test_decode_adversarial_unknownKeysAndNulls` (`list-adversarial.json` decodes, `linkedVersion` nil — Review Focus 1). Key conversion: snake_case JSON ↔ camelCase Swift via explicit `CodingKeys` per item struct.
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `ListJSON.swift`** as above; `decode` uses a single `JSONDecoder` on the whole document.
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: list --json decoding (casks keyed on token)"`.

---

### Task 4: `info --json=v2 --installed` decoding

**Files:**
- Create: `Sources/BreweryCore/InfoJSON.swift`, `Tests/BreweryCoreTests/InfoJSONTests.swift`

**Interfaces:**
- Consumes: `Fixtures/info.json`.
- Produces (Task 6, Task 7 consume):

```swift
public struct InfoSnapshot {
    public struct InstalledRecord { public let version: String; public let time: Date? } // JSON time = epoch seconds
    public struct FormulaInfo { public let name: String; public let fullName: String; public let tap: String
        public let installed: [InstalledRecord]; public let linkedKeg: String?
        public let pinned: Bool; public let outdated: Bool
        public let deprecated: Bool; public let deprecationReason: String?
        public let disabled: Bool; public let disabledReason: String?
        public let kegOnly: Bool; public let desc: String?; public let homepage: String?
        public let dependencies: [String]; public let versionsStable: String?
        public let bottleTag: String? }   // first key of bottle.stable.files, e.g. "arm64_golden_gate"
    public struct CaskInfo { public let token: String; public let installedVersion: String?  // cask `installed` is a STRING, not array — §45
        public let installedTime: Date?; public let outdated: Bool; public let pinned: Bool
        public let deprecated: Bool; public let deprecationReason: String?
        public let autoUpdates: Bool; public let versionLatest: String?   // `version` field
        public let desc: String?; public let homepage: String?; public let tap: String }
    public static func decode(_ data: Data) throws -> InfoSnapshot
}
```

- [ ] **Step 1: Write failing `InfoJSONTests.swift`** — `test_decode_realFixture` (ace: `installed[0].version == "8.0.8"`, `bottleTag == "arm64_golden_gate"`; wireshark-app cask: `installedVersion` non-nil — pins the string-not-array shape), `test_decode_adversarial_missingOptionals` (hand-trim a copy of the ace entry removing `license`, `service`, `caveats`, set `linked_keg: null`; decode succeeds with nils — Review Focus 1).
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `InfoJSON.swift`.** Custom `init(from:)` for `CaskInfo` (cask `installed` decodes as `String?`, time from `installed_time` epoch seconds). Missing booleans default to `false`; missing `[String]` default to `[]`.
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: info --json=v2 --installed decoding"`.

---

### Task 5: Plain-text `list --versions` fallback

**Files:**
- Create: `Sources/BreweryCore/TextList.swift`, `Tests/BreweryCoreTests/TextListTests.swift`

**Interfaces:**
- Consumes: `Fixtures/text-list-real.txt`.
- Produces (Task 9 consumes): `public func parseTextListVersions(_ text: String) -> [(name: String, versions: [String])]`

- [ ] **Step 1: Write failing `TextListTests.swift`** — `test_singleVersion` (`"ace 8.0.8\n"` → `("ace", ["8.0.8"])`), `test_multiVersion` (`"node 25.2.1 24.10.0"` → two versions, order preserved), `test_emptyAndBlankLines`, `test_realFixture_hasRalphex` (Review Focus 2's fallback source).
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `TextList.swift`** — split lines, first token is name, rest are versions; skip blank lines.
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: plain-text list --versions fallback parser"`.

---

### Task 6: Inventory merger

**Files:**
- Create: `Sources/BreweryCore/InventoryMerger.swift`, `Tests/BreweryCoreTests/InventoryMergerTests.swift`

**Interfaces:**
- Consumes: `ListSnapshot` (Task 3), `InfoSnapshot` (Task 4), `BrewItem` (Task 1).
- Produces: `public struct InventoryMerger { public static func merge(list: ListSnapshot, info: InfoSnapshot) -> [BrewItem] }` — sorted case-insensitively by `name`.

- [ ] **Step 1: Write failing `InventoryMergerTests.swift`** — `test_formulaMergesInfoOntoListRow` (ace: `desc` non-nil, `tap == "homebrew/core"`, `sourceState == .complete`), `test_casksMergeOnToken` (all 3 casks merged; pins Review Focus 3), `test_untrustedRowStaysAsListOnly` (ralphex present with `sourceState == .listOnly(reason: …)`, `latestVersion == nil`, `desc == nil` — Review Focus 2), `test_reverseSkewInfoOnlyRow` (formula in info fixture but absent from list fixture → `sourceState == .infoOnly`), `test_sortedByName`.
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `InventoryMerger.swift`** — index info by `name` (formulae) and `token` (casks); unmatched list rows become `listOnly(reason: "no source info — untrusted tap or API skew")`; `installedAt` from `installed[0].time` (formula) / `installedTime` (cask).
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: inventory merger with untrusted-tap listOnly rows"`.

---

### Task 7: Package manifest fetch, cache, lookup

**Files:**
- Create: `Sources/BreweryCore/Manifest.swift`, `Tests/BreweryCoreTests/ManifestTests.swift`, `Tests/BreweryCoreTests/Fixtures/manifest-mini.json`

**Interfaces:**
- Consumes: `InfoSnapshot.FormulaInfo.bottleTag` (Task 4) to build the endpoint.
- Produces (Tasks 8–9 consume):

```swift
public struct PackageManifest {
    public let bottleTag: String
    public func latestFormulaVersion(name: String) -> String?   // formulae[name].stable_version
    public func latestCaskVersion(token: String) -> String?     // casks[token].version
    public static func decode(jwsData: Data) throws -> PackageManifest
}
public protocol HTTPFetching: Sendable { func fetch(_ url: URL) async throws -> Data }
public final class ManifestFetcher {
    public init(http: HTTPFetching, cacheDirectory: URL)
    public func manifest(bottleTag: String, now: Date) async throws -> PackageManifest
    public static func isStale(fetchedAt: Date?, now: Date, threshold: TimeInterval) -> Bool // threshold passed as 86_400
    public static func endpointURL(bottleTag: String) -> URL // https://formulae.brew.sh/api/internal/packages.\(tag).jws.json
}
```

- [ ] **Step 1: Create `manifest-mini.json`** — extract from brew's own cache (read-only): payload of `~/Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json.payload` (parse the wrapper's JSON value first, then the payload JSON value after it — two `JSONDecoder().raw_decode` passes), keeping only `metadata`, and within `formulae` the key `"ace"`, and within `casks` `"wireshark-app"`. Test input wraps it as compact JWS: `"\(headerBase64url).\(miniPayloadJSON).\(dummySignature)"` built inside the test (`decode` must not require signature validity — Global Constraints).
- [ ] **Step 2: Write failing `ManifestTests.swift`** — `test_decode_and_lookup` (ace → `stable_version`; wireshark-app → `version`; unknown name → nil), `test_endpointURL_shape` (contains `/api/internal/packages.arm64_golden_gate.jws.json`), `test_isStale_boundaries` (23 h fresh @ 86_400 threshold; 25 h stale; nil fetchedAt is stale), `test_fetcher_cachesAndRespectsStaleness` (`FakeHTTP` counts calls: first fetch, second call with same `now` inside threshold → 1 call total), `test_fetcher_offlineUsesCache` (HTTP throws on second call; stale threshold forces refetch; returns cached manifest).
- [ ] **Step 3: Run `swift test`** — expect FAIL.
- [ ] **Step 4: Implement `Manifest.swift`.** `decode`: split compact JWS at first `.` and last `.` — payload is raw JSON between them (manifest header is `b64:false`, verified §23 note); `formulae`/`casks` are dicts keyed by name/token; resolve formula aliases via the payload's `formula_aliases` map (alias → canonical name). `ManifestFetcher` persists payload + `fetchedAt` in `cacheDirectory` (files `manifest.<tag>.json`, `manifest.<tag>.fetched_at`).
- [ ] **Step 5: Run `swift test`** — expect PASS.
- [ ] **Step 6: Commit** `git commit -m "feat: brew package manifest fetch/cache/lookup"`.

---

### Task 8: Outdated policy

**Files:**
- Create: `Sources/BreweryCore/OutdatedPolicy.swift`, `Tests/BreweryCoreTests/OutdatedPolicyTests.swift`

**Interfaces:**
- Consumes: `BrewItem` (Task 1), `PackageManifest` (Task 7).
- Produces (Tasks 9–10 consume):

```swift
public enum OutdatedState: Equatable {
    case upToDate
    case updateAvailable(latest: String)
    case selfUpdating(latestKnown: String?)
    case unknown
}
public func latestVersion(for item: BrewItem, manifest: PackageManifest?) -> String?
public func outdatedState(item: BrewItem, manifest: PackageManifest?, greedy: Bool) -> OutdatedState
```

Semantics (spec Freshness decisions): formula compares `latestFormulaVersion` vs `installedVersions` stable entry; cask compares `latestCaskVersion` vs `installedVersion`; casks with `autoUpdates == true` or `versionLatest == ":latest"` are NOT counted unless `greedy` (brew-default). Manifest miss → `latestVersion` nil + `.unknown`.

- [ ] **Step 1: Write failing `OutdatedPolicyTests.swift`** — `test_formulaUpdateAvailable` (installed 8.0.8, manifest 8.1.0 → `.updateAvailable(latest: "8.1.0")`), `test_formulaUpToDate`, `test_tapPackageUnknownNotUpToDate` (manifest lacks name → `.unknown`, `latestVersion` nil — Review Focus 5), `test_autoUpdatesCaskNotCountedByDefault` (installed 4.6.9, manifest 4.7.0, `autoUpdates` true, greedy false → `.upToDate`), `test_autoUpdatesCaskGreedyFlagsSelfUpdating` (same item, greedy true → `.selfUpdating(latestKnown: "4.7.0")`), `test_plainCaskUpdateAvailable`.
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `OutdatedPolicy.swift`** per the semantics paragraph.
- [ ] **Step 4: Run `swift test`** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: outdated policy with greedy toggle semantics"`.

---

### Task 9: Snapshot store and inventory model

**Files:**
- Create: `Sources/BreweryCore/SnapshotStore.swift`, `Sources/BreweryCore/InventoryModel.swift`, `Tests/BreweryCoreTests/InventoryModelTests.swift`

**Interfaces:**
- Consumes: `CommandRunning` (Task 2), `ListSnapshot`/`InfoSnapshot` decoders (Tasks 3–4), `parseTextListVersions` (Task 5), `InventoryMerger` (Task 6), `ManifestFetcher` (Task 7), `outdatedState`/`latestVersion` (Task 8).
- Produces (Task 10 consumes):

```swift
public final class SnapshotStore {
    public enum Kind: String { case listJSON, infoJSON, textList }
    public init(directory: URL)
    public func save(_ data: Data, kind: Kind) throws
    public func loadLatest(_ kind: Kind) -> (data: Data, savedAt: Date)?
}
public enum RefreshReason { case manual, focus }
public struct InventorySettings { public var greedyOutdated: Bool = false
    public var focusStaleness: TimeInterval = 300; public var manifestThreshold: TimeInterval = 86_400 }
public protocol ExternalBrewProbing: Sendable { func isBrewRunningExternally() -> Bool }
// production conformance: ProcessInfo-free `pgrep -x brew` exit-code probe, one line
@MainActor @Observable public final class InventoryModel {
    public enum ViewState: Equatable { case idle, loading, ready, failed(message: String) }
    public private(set) var items: [BrewItem] = []
    public private(set) var state: ViewState = .idle
    public private(set) var inventoryUpdated: Date?
    public private(set) var versionDataAsOf: Date?
    public init(runner: CommandRunning, manifestFetcher: ManifestFetcher, store: SnapshotStore,
        brewProbe: ExternalBrewProbing, jqAvailable: Bool, settings: InventorySettings)
    public func refresh(reason: RefreshReason) async
}
```

- [ ] **Step 1: Write failing `InventoryModelTests.swift`** — with a `FakeRunner: CommandRunning` (scripted per-args `BrewResult`s + a call log), `FakeProbe`, temp-dir `SnapshotStore`, `FakeHTTP`:
  - `test_manual_refresh_mergesAndAppliesPolicy` — list+info fixtures as args-appropriate results; after `refresh(.manual)`: `state == .ready`, ralphex row `listOnly`, ace `outdated == .upToDate` (fixture manifest).
  - `test_focusRefreshDeferredWhileExternalBrewRunning` — probe true, reason `.focus` → zero runner calls, items unchanged (Review Focus 4).
  - `test_manualRefreshDuringExternalBrewSurfacesBrewError` — probe true, runner exits 1 with stderr `"Error: Cannot lock..."` → `state == .failed(message:)` containing that stderr plus hint "brew is busy".
  - `test_focusRefreshBacksOff60sAfterFailure` — second `.focus` refresh within 60 s of the failure → no runner call.
  - `test_singleFlight` — two concurrent `refresh(.manual)` calls → runner saw exactly one list call.
  - `test_degradedTextFallbackWhenJqMissing` — `jqAvailable: false`; runner receives `["list", "--versions"]` (no `--json`); ralphex row present (Review Focus 2 fallback).
  - `test_listRowsPublishBeforeInfo` — FakeRunner gated by `CheckedContinuation` on info call; await a mid-refresh checkpoint asserting `items.count == list-only count` before resuming.
- [ ] **Step 2: Run `swift test`** — expect FAIL.
- [ ] **Step 3: Implement `SnapshotStore.swift`** (files `snapshot.<kind>` + mtime as `savedAt`).
- [ ] **Step 4: Implement `InventoryModel.swift`.** Refresh pipeline: focus-gate (probe + staleness + backoff) → run `["list","--json","--versions"]` and `["info","--json=v2","--installed"]` concurrently → on jq-missing substitute text path → decode defensively (decode failure for info alone = continue with list-only items) → `InventoryMerger.merge` → publish `items` → `ManifestFetcher.manifest(bottleTag:from info, now:)` (bottleTag from first formula's `bottleTag`; nil → manifest step skipped, all latests nil) → per-item `latestVersion`/`outdated` assignment → save raw snapshots. Keep a `refreshTask: Task<Void, Never>?` for single-flight; failure sets `failed(message: stderr-tail + hints)`.
- [ ] **Step 5: Run `swift test`** — expect PASS.
- [ ] **Step 6: Commit** `git commit -m "feat: snapshot store + inventory model refresh orchestration"`.

---

### Task 10: SwiftUI shell and manual verification

**Files:**
- Create: `Sources/BreweryCore/InventorySections.swift`, `Tests/BreweryCoreTests/InventorySectionsTests.swift`, `Sources/BreweryApp/ContentView.swift`, `Sources/BreweryApp/Sidebar.swift`, `Sources/BreweryApp/PackageList.swift`, `Sources/BreweryApp/PackageDetail.swift`; modify `Sources/BreweryApp/BreweryApp.swift`
- Modify: none in core except `InventorySections.swift` (new).

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces:

```swift
public enum Section: String, CaseIterable { case all, formulae, casks, outdated, pinned, deprecated }
public func items(_ items: [BrewItem], in section: Section, query: String?, greedy: Bool) -> [BrewItem]
// query: case-insensitive substring over name + desc; nil = no filter (local filter, spec Goal 5)
public func sidebarCounts(_ items: [BrewItem], greedy: Bool) -> [Section: Int]
```

- [ ] **Step 1: Write failing `InventorySectionsTests.swift`** — `test_counts_match_design_snapshot` (built from fixtures: formulae/casks counts; outdated 0 with greedy false, `selfUpdating` items counted with greedy true), `test_outdatedSectionExcludesUnknown`, `test_filterByNameSubstring` (`query: "ral"` keeps ralphex+ralph-only names, nil query keeps all — the local filter from spec Goal 5).
- [ ] **Step 2: Run `swift test`** — expect FAIL; implement `InventorySections.swift`; PASS.
- [ ] **Step 3: Assemble the UI.** `BreweryApp.swift`: production composition (discoverBrew → BrewRunner → ManifestFetcher(URLSession impl) → SnapshotStore(`~/Library/Application Support/brewery`) → pgrep probe) + `Settings` scene with the `greedyOutdated` toggle (default off) and brew-path override field. If the SwiftPM executable window starts inactive, add `NSApp.activate(ignoringOtherApps: true)` in an `onAppear`. `ContentView`: three-column `NavigationSplitView` per spec layout — Sidebar sections + counts + footer `Updated HH:MM · Version data as of HH:MM`; PackageList rows (kind glyph, name, desc, `installed → latest` with accent arrow when `.updateAvailable`, "—" when `.unknown`, pin/deprecated badges, local filter field); PackageDetail fields per spec (tap, linked/keg-only, installed-at, bottle tag, dependency names, caveats via `desc`/homepage button opening browser through `NSWorkspace`). State UI: skeleton while loading; empty-state text; `.failed` banner with message; brew-not-found setup sheet pointing at the override field; degraded-mode banner when jq was missing.
- [ ] **Step 4: Run unit tests once more** — expect PASS.
- [ ] **Step 5: Manual verification** — `swift run BreweryApp`, then check, in order: (1) rows appear within ~1 s, sidebar counts match `brew list --json --versions` counts on this machine (formulae 152 / casks 3 today); (2) `⌘R` re-refreshes with skeleton; (3) filter `ralph` → ralphex row visible with "—" latest and untrusted explanation; (4) detail pane for `ace` shows bottle tag `arm64_golden_gate` and dep names; (5) start `brew list --versions > /dev/null` in Terminal, refocus the app: no refresh fires; refocus after it exits: refresh fires within staleness window; (6) greedy ON: `wireshark-app` row behavior matches Task 8 semantics (`auto_updates` casks only — verify against the row's actual state and Settings). Record any mismatch in the task's commit message and fix before committing.
- [ ] **Step 6: Commit** `git commit -m "feat: SwiftUI inventory shell — sidebar, list, detail, settings"`.

---

## Spec coverage notes (self-review)

- Spec §"Left to the builder" items (detail-pane placement, iconography, cache format) appear as builder freedom in Tasks 10/9 — intentional.
- Spec hook points (mutating-slice runner reuse, watch-slice snapshot) are Task 2's `CommandRunning` seam and Task 9's `SnapshotStore` — present, no extra scope built.
- Detail pane `caveats` field: `InfoJSON` does not decode `caveats` yet; Task 10 Step 3 shows only what core decodes — adding caveats is a one-line `FormulaInfo`/`CaskInfo` field if the builder wants it; marked as builder choice.
