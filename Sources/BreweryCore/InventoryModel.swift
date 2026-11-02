import Foundation
import Observation

public enum RefreshReason { case manual, focus }

public struct InventorySettings {
    public var greedyOutdated: Bool = false
    public var focusStaleness: TimeInterval = 300
    public var manifestThreshold: TimeInterval = 86_400
    public init() {}
}

/// Does a brew process the app did not start exist right now?
public protocol ExternalBrewProbing: Sendable { func isBrewRunningExternally() -> Bool }

/// Production probe: `pgrep -x brew`, exit code as data (0 = some brew is running).
public struct PgrepBrewProbe: ExternalBrewProbing {
    public init() {}
    public func isBrewRunningExternally() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "brew"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Seam so tests can fake the manifest fetch without faking HTTP (Task 7's
/// ManifestFetcher conforms to this).
public protocol ManifestFetching: Sendable {
    func fetch(bottleTag: String, now: Date, force: Bool) async throws -> ManifestFetchResult
}

extension ManifestFetcher: ManifestFetching {}

/// Which brew step an upgrade is running right now (drives the UI progress label).
public enum UpgradePhase: Equatable { case updatingHomebrew, upgradingPackages }

/// A tap mutation the app performed (or is performing). Wording lives here so
/// the banner names the action the user confirmed, not a generic "working…".
public enum TapAction: Equatable {
    case tapping(name: String), untapping(name: String)
    case trusting(name: String), untrusting(name: String)
    case trustingItem(qualified: String), untrustingItem(qualified: String)
    case installing(qualified: String), uninstalling(qualified: String)
    case pinning(qualified: String), unpinning(qualified: String)
    case switchingToVersion(qualified: String, version: String), relinkingTo(qualified: String, version: String)

    public var label: String {
        switch self {
        case .tapping(let n): "Tapping \(n)…"
        case .untapping(let n): "Untapping \(n)…"
        case .trusting(let n): "Trusting \(n)…"
        case .untrusting(let n): "Untrusting \(n)…"
        case .trustingItem(let q): "Trusting \(q)…"
        case .untrustingItem(let q): "Untrusting \(q)…"
        case .installing(let q): "Installing \(q)…"
        case .uninstalling(let q): "Uninstalling \(q)…"
        case .pinning(let q): "Pinning \(q)…"
        case .unpinning(let q): "Unpinning \(q)…"
        case .switchingToVersion(let q, let v): "Switching \(q) to \(v)…"
        case .relinkingTo(let q, let v): "Relinking \(q) to \(v)…"
        }
    }
}

/// Tap-action state, kept apart from ViewState and UpgradeState so a failed
/// `brew untap` is not reported as a refresh or upgrade failure.
public enum TapActionState: Equatable {
    case idle
    case running(TapAction)
    case failed(action: TapAction, message: String)
}

/// Upgrade-action state, separate from ViewState so an upgrade failure never
/// masquerades as a refresh failure (and vice versa).
public enum UpgradeState: Equatable { case idle, running(phase: UpgradePhase), failed(message: String) }

@MainActor
@Observable
public final class InventoryModel {
    public enum ViewState: Equatable { case idle, loading, ready, failed(message: String) }

    public private(set) var items: [BrewItem] = []
    public private(set) var state: ViewState = .idle
    public private(set) var upgrade: UpgradeState = .idle
    public private(set) var inventoryUpdated: Date?
    public private(set) var versionDataAsOf: Date?
    public private(set) var manifestBottleTag: String? // the bottle tag the manifest was fetched for
    /// Fetched lists keyed by analytics window; the Brew picker switches
    /// periods without refetching a window already loaded this launch.
    public private(set) var topInstalls: [AnalyticsPeriod: TopInstallsResult] = [:]
    public private(set) var topInstallsState: ViewState = .idle
    public private(set) var taps: [TapInfo] = []
    public private(set) var tapsState: ViewState = .idle
    public private(set) var tapsUpdated: Date?
    public private(set) var tapAction: TapActionState = .idle
    /// true when taps came from `brew tap` (names only) because jq is absent.
    public private(set) var tapsNamesOnly = false
    /// Item-level trust grants (`brew trust --json=v1`); nil = unknown (read failed).
    public private(set) var trustStore: TrustStore?
    /// The core catalog manifest from the last refresh (drives the Install pane's
    /// search, design 2026-11-02); nil until a refresh has fetched it.
    public private(set) var manifest: PackageManifest?
    public var settings: InventorySettings

    private let runner: CommandRunning
    private let manifestFetcher: ManifestFetching
    private let topInstallsFetcher: TopInstallsFetching
    private let store: SnapshotStore
    private let brewProbe: ExternalBrewProbing
    private let jqAvailable: Bool

    private var refreshTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var tapsTask: Task<Void, Never>?
    private var topInstallsTask: Task<Void, Never>?
    private var tapActionTask: Task<Void, Never>?
    private var lastFailure: Date?
    private static let failureBackoff: TimeInterval = 60

    public init(runner: CommandRunning, manifestFetcher: ManifestFetching, store: SnapshotStore,
                brewProbe: ExternalBrewProbing, jqAvailable: Bool, settings: InventorySettings,
                topInstallsFetcher: TopInstallsFetching = TopInstallsFetcher()) {
        self.runner = runner
        self.manifestFetcher = manifestFetcher
        self.topInstallsFetcher = topInstallsFetcher
        self.store = store
        self.brewProbe = brewProbe
        self.jqAvailable = jqAvailable
        self.settings = settings
    }

    public func refresh(reason: RefreshReason, forceManifest: Bool = false) async {
        if let existing = refreshTask { await existing.value; return } // single flight
        if reason == .focus, focusGateBlocks(now: Date()) { return }
        let task = Task { await self.performRefresh(forceManifest: forceManifest) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Focus refresh defers while: an external brew is running (never contend
    /// with it), a recent failure is within backoff, or data is already fresh.
    private func focusGateBlocks(now: Date) -> Bool {
        if brewProbe.isBrewRunningExternally() { return true }
        if let lastFailure, now.timeIntervalSince(lastFailure) < Self.failureBackoff { return true }
        if let inventoryUpdated, now.timeIntervalSince(inventoryUpdated) < settings.focusStaleness { return true }
        return false
    }

    private func performRefresh(forceManifest: Bool) async {
        state = .loading
        let now = Date()

        let listArgs: [String] = jqAvailable ? ["list", "--json", "--versions"] : ["list", "--versions"]
        do {
            let listRes = try await runner.run(listArgs)
            guard listRes.exitCode == 0 else { fail(message: failureMessage(for: listRes)); return }

            let listSnapshot: ListSnapshot
            if jqAvailable {
                listSnapshot = try ListSnapshot.decode(listRes.stdout)
            } else {
                // brew needs jq to emit --json; without it the plain-text form is the fallback (§43).
                // Plain `list --versions` mixes cask rows in; fetch casks separately and split.
                let rows = parseTextListVersions(String(decoding: listRes.stdout, as: UTF8.self))
                let caskRes = try await runner.run(["list", "--cask", "--versions"])
                let caskRows = caskRes.exitCode == 0
                    ? parseTextListVersions(String(decoding: caskRes.stdout, as: UTF8.self)) : []
                let caskNames = Set(caskRows.map(\.name))
                listSnapshot = ListSnapshot(
                    formulae: rows.filter { !caskNames.contains($0.name) }.map {
                        ListSnapshot.FormulaItem(name: $0.name, versions: $0.versions,
                                                 linkedVersion: nil, optlinkedVersion: nil, pinnedVersion: nil)
                    },
                    casks: caskRows.map { ListSnapshot.CaskItem(token: $0.name, versions: $0.versions,
                                                                pinnedVersion: nil) })
            }

            // Publish list rows immediately — the UI shows inventory while info runs.
            items = InventoryMerger.merge(list: listSnapshot, info: InfoSnapshot(formulae: [], casks: []))

            var infoSnapshot = InfoSnapshot(formulae: [], casks: [])
            var infoRaw: Data?
            if jqAvailable {
                do {
                    let infoRes = try await runner.run(["info", "--json=v2", "--installed"])
                    if infoRes.exitCode == 0 {
                        infoSnapshot = try InfoSnapshot.decode(infoRes.stdout)
                        infoRaw = infoRes.stdout
                    }
                } catch { /* decode failure → continue with list-only items (defensive) */ }
            }

            var merged = InventoryMerger.merge(list: listSnapshot, info: infoSnapshot)

            let bottleTag = infoSnapshot.formulae.compactMap(\.bottleTag).first
            var manifest: PackageManifest?
            if let bottleTag {
                // fetchedAt (not refresh time): a cached or stale-served manifest
                // must show its real age in the footer (Freshness #1).
                let manifestResult = try? await manifestFetcher.fetch(bottleTag: bottleTag, now: now, force: forceManifest)
                manifest = manifestResult?.manifest
                versionDataAsOf = manifestResult?.fetchedAt
            } else {
                versionDataAsOf = nil // no info → no bottleTag → manifest step skipped
            }
            self.manifest = manifest
            manifestBottleTag = manifest != nil ? bottleTag : nil
            applyPolicy(to: &merged, manifest: manifest)

            items = merged
            inventoryUpdated = now

            try? store.save(listRes.stdout, kind: jqAvailable ? .listJSON : .textList)
            if let infoRaw { try? store.save(infoRaw, kind: .infoJSON) }

            state = .ready
        } catch {
            fail(message: "brew command failed: \(error.localizedDescription)")
        }
    }

    /// Outdated-section "Update All": `brew update`, then `brew upgrade` with
    /// no package args — brew picks exactly the same outdated set its own CLI
    /// would (pinned skipped, deprecated warned, disabled failed; compat §70).
    public func upgradeAll() async {
        await runUpgrade(scope: .all)
    }

    /// Detail-page per-package upgrade. --greedy is added for a .selfUpdating
    /// item, the only way brew will touch a :latest/auto_updates cask (§70).
    public func upgrade(_ item: BrewItem) async {
        await runUpgrade(scope: .single(item))
    }

    private enum UpgradeScope { case all, single(BrewItem) }

    private func runUpgrade(scope: UpgradeScope) async {
        if let existing = upgradeTask { await existing.value; return } // single flight
        if let refresh = refreshTask { await refresh.value } // never two brews fighting our own
        let task = Task { await self.performUpgrade(scope: scope) }
        upgradeTask = task
        await task.value
        upgradeTask = nil
    }

    private func performUpgrade(scope: UpgradeScope) async {
        if brewProbe.isBrewRunningExternally() {
            upgrade = .failed(message: "brew is busy (another brew process is running) — wait for it, then retry")
            return
        }
        do {
            // Explicit `brew update` first: brew upgrade consults brew's own API
            // cache, and the runner's HOMEBREW_NO_AUTO_UPDATE suppresses the
            // implicit update — without this step upgrade can lag the manifest
            // the badges were computed from, and say "already up-to-date".
            upgrade = .running(phase: .updatingHomebrew)
            let updateRes = try await runner.run(["update"])
            guard updateRes.exitCode == 0 else { failUpgrade(result: updateRes); return }

            upgrade = .running(phase: .upgradingPackages)
            // -y: ask mode is brew's default and a TTY prompt would hang the GUI (§77);
            // the app runs its own confirmation instead.
            var args: [String] = ["upgrade", "-y"]
            switch scope {
            case .all:
                if settings.greedyOutdated { args.append("--greedy") }
            case .single(let item):
                if case .selfUpdating = item.outdated { args.append("--greedy") }
                args.append(item.fullName)
            }
            let upgradeRes = try await runner.run(args)
            guard upgradeRes.exitCode == 0 else { failUpgrade(result: upgradeRes); return }

            upgrade = .idle
            // Badges must reflect the new reality: re-read inventory and force
            // the manifest past its 24 h cache.
            await performRefresh(forceManifest: true)
        } catch {
            upgrade = .failed(message: "brew command failed: \(error.localizedDescription)")
        }
    }

    private func failUpgrade(result: BrewResult) {
        upgrade = .failed(message: failureMessage(for: result))
    }

    // MARK: - Taps

    /// Taps load lazily (the Taps pane asks for them), never as part of an
    /// inventory refresh: `tap-info --installed --json` is ~2 s and ~340 KB on
    /// this machine because the official API taps list every token (compat §7).
    public func loadTaps(force: Bool = false) async {
        if let existing = tapsTask { await existing.value; return } // single flight
        if !force, tapsState == .ready { return }
        if let refresh = refreshTask { await refresh.value } // never two brews of ours at once
        let task = Task { await self.performLoadTaps() }
        tapsTask = task
        await task.value
        tapsTask = nil
    }

    /// `brew tap user/repo [URL]` (mutating). The GUI confirms first; the name
    /// is validated here too so a malformed target never reaches brew.
    public func addTap(name: String, remote: String?) async {
        guard case .success(let parts) = parseTapName(name) else {
            tapAction = .failed(action: .tapping(name: name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                message: parseTapNameError(name))
            return
        }
        if let problem = validateTapRemote(remote ?? "") {
            tapAction = .failed(action: .tapping(name: "\(parts.user)/\(parts.repo)"), message: problem)
            return
        }
        let qualified = "\(parts.user)/\(parts.repo)"
        var args = ["tap", qualified]
        let trimmedRemote = (remote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRemote.isEmpty { args.append(trimmedRemote) } // two-argument form: any git transport (§7)
        await runTapAction(.tapping(name: qualified), args: args, reloadInventory: true)
    }

    /// `brew untap [--force] <tap>`. --force uninstalls the tap's packages
    /// first, which is the only way brew lets a tap with installed items go
    /// away; the GUI exposes that as a separate confirmed choice.
    public func removeTap(_ tap: TapInfo, uninstallingItems: Bool) async {
        var args = ["untap"]
        if uninstallingItems { args.append("--force") }
        args.append(tap.name)
        await runTapAction(.untapping(name: tap.name), args: args, reloadInventory: true)
    }

    /// Tap-level trust (`brew trust --tap`), the knob brew itself suggests when
    /// it prints "Skipping <tap> because it is not trusted" (compat §7).
    /// It re-reads the inventory too: trusting a tap is what makes `brew info`
    /// report its installed packages at all, so the rows change shape (§43).
    public func trustTap(_ tap: TapInfo) async {
        await runTapAction(.trusting(name: tap.name), args: ["trust", "--tap", tap.name], reloadInventory: true)
    }

    public func untrustTap(_ tap: TapInfo) async {
        await runTapAction(.untrusting(name: tap.name), args: ["untrust", "--tap", tap.name], reloadInventory: true)
    }

    /// Item-level trust (`brew trust --formula|--cask <tap>/<name>`): lets brew load
    /// ONE tap definition while the tap itself stays untrusted (§22). Inventory is
    /// re-read because a trusted installed item finally appears in `info --installed` (§43).
    public func trustItem(qualified: String, kind: BrewItem.Kind) async {
        await runTapAction(.trustingItem(qualified: qualified),
                           args: ["trust", Self.kindFlag(kind), qualified], reloadInventory: true)
    }

    public func untrustItem(qualified: String, kind: BrewItem.Kind) async {
        await runTapAction(.untrustingItem(qualified: qualified),
                           args: ["untrust", Self.kindFlag(kind), qualified], reloadInventory: true)
    }

    /// `brew install -y <tap>/<name>`. -y because ask mode is brew's install default
    /// and a TTY prompt would hang the GUI (same posture as upgrade, §77). A
    /// fully-qualified install grants the item's trust itself — observed 2026-10-30:
    /// brew trusted `umputun/apps/mpt` from an *untrusted* tap (§22) — so no separate
    /// trust step gates this button.
    public func installItem(_ qualified: String) async {
        await runTapAction(.installing(qualified: qualified), args: ["install", "-y", qualified], reloadInventory: true)
    }

    /// `brew uninstall --formula|--cask <qualified>` (compat §26). No `-y`: brew 7.0.11's
    /// uninstall flag set has no -y/--yes and uninstall never shows the ask-mode prompt
    /// (verified via `brew uninstall --help`), so there is no TTY prompt to hang the GUI
    /// (contrast install, §77). brew also auto-runs `Cleanup.autoremove` after a successful
    /// uninstall unless HOMEBREW_NO_AUTOREMOVE is set — orphaned deps can leave with it;
    /// the GUI warns before confirming and the inventory re-read shows the result.
    /// - allVersions → `--force`: brew's default scope is the linked keg only
    ///   (cmd/uninstall.rb `:default_kegs`); --force deletes every installed version.
    ///   Formula-only in the GUI: for casks --force instead means "uninstall even if not
    ///   installed / ignore errors", which the GUI should not reach for silently.
    /// - ignoreDependencies → `--ignore-dependencies`: brew refuses to uninstall a package
    ///   other installed packages depend on ("Refusing to uninstall … You can override
    ///   this and force removal with: brew uninstall --ignore-dependencies …",
    ///   dependents_message.rb); pinned packages brew refuses outright.
    public func uninstallItem(qualified: String, kind: BrewItem.Kind,
                              allVersions: Bool = false, ignoreDependencies: Bool = false) async {
        var args = ["uninstall"]
        if allVersions { args.append("--force") }
        if ignoreDependencies { args.append("--ignore-dependencies") }
        args.append(Self.kindFlag(kind))
        args.append(qualified)
        await runTapAction(.uninstalling(qualified: qualified), args: args, reloadInventory: true)
    }

    /// `brew pin|unpin --formula|--cask <qualified>` (compat §93). brew accepts only
    /// installed names; the kind flag disambiguates a formula and cask sharing a name.
    /// reloadInventory because the pin lives in the info JSON `pinned` field and drives
    /// the Pinned section plus every Update button's disabled state.
    public func pinItem(qualified: String, kind: BrewItem.Kind) async {
        await runTapAction(.pinning(qualified: qualified),
                           args: ["pin", Self.kindFlag(kind), qualified], reloadInventory: true)
    }

    public func unpinItem(qualified: String, kind: BrewItem.Kind) async {
        await runTapAction(.unpinning(qualified: qualified),
                           args: ["unpin", Self.kindFlag(kind), qualified], reloadInventory: true)
    }

    // MARK: - Version switching (compat §27)

    /// What a "switch to <version>" click would run for this row — drives the
    /// detail page's row button and the confirm sheet copy.
    public func versionSwitchPlan(for item: BrewItem, to version: String) -> VersionSwitchPlan {
        BreweryCore.versionSwitchPlan(for: item, to: version, items: items, taps: taps)
    }

    /// Switch this family to `version` (formulae only; casks have no versioned
    /// installs — compat §27). Two brew-faithful routes:
    /// - Target keg already installed → `brew unlink` the linked family kegs, then
    ///   `brew link` the target rack (`--force` only for keg-only, the flag brew's
    ///   own help names for linking them). Nothing re-downloads.
    /// - Target keg missing → `brew extract --force --version=<v> <name> <tap>`
    ///   materializes the definition (brew has no `wget@1.21.1` to install until
    ///   some tap defines it — live-probed 2026-11-02), then unlink the linked
    ///   family kegs (install's symlinks would collide with them), then
    ///   `brew install -y <tap>/<name>@<v>`. The old keg stays installed but
    ///   unlinked, so switching back is the relink route.
    /// For a core formula on an API-mode machine the clone step `brew tap
    /// homebrew/core` runs first — extract's `source_tap.installed?` gate refuses
    /// history queries against the virtual tap (`dev-cmd/extract.rb`, `tap.rb`).
    /// Mid-sequence failure still reloads taps+inventory: the tap clone and the
    /// extracted file are already on disk even when a later step failed.
    public func switchFormulaVersion(item: BrewItem, version: String, destinationTap: String) async {
        if let existing = tapActionTask { await existing.value; return } // one mutation at a time
        if let refresh = refreshTask { await refresh.value }
        if let upgrade = upgradeTask { await upgrade.value }
        if brewProbe.isBrewRunningExternally() {
            tapAction = .failed(action: .switchingToVersion(qualified: item.fullName, version: version),
                                message: "brew is busy (another brew process is running) — wait for it, then retry")
            return
        }
        let plan = versionSwitchPlan(for: item, to: version)
        let action: TapAction = switch plan {
        case .relink: .relinkingTo(qualified: item.fullName, version: version)
        default: .switchingToVersion(qualified: item.fullName, version: version)
        }
        let task = Task { await self.performSwitch(action: action, plan: plan,
                                                   destinationTap: destinationTap, item: item, version: version) }
        tapActionTask = task
        await task.value
        tapActionTask = nil
    }

    private func performSwitch(action: TapAction, plan: VersionSwitchPlan, destinationTap: String,
                               item: BrewItem, version: String) async {
        tapAction = .running(action)
        var failure: String?
        do {
            switch plan {
            case .blocked(let reason):
                failure = reason
            case .relink(let rack, let unlinkRacks, let kegOnly):
                for rackName in unlinkRacks {
                    let res = try await runner.run(["unlink", "--formula", rackName])
                    if res.exitCode != 0 { failure = failureMessage(for: res); break }
                }
                if failure == nil {
                    var args = ["link", "--formula"]
                    if kegOnly { args.append("--force") }
                    args.append(rack)
                    let res = try await runner.run(args)
                    if res.exitCode != 0 { failure = failureMessage(for: res) }
                }
            case .extractInstall(let sourceName, let ver, let sourceTap, _, let needsClone):
                if needsClone {
                    let res = try await runner.run(["tap", sourceTap])
                    if res.exitCode != 0 { failure = failureMessage(for: res) }
                }
                if failure == nil {
                    let res = try await runner.run(["extract", "--force", "--version=\(ver)", sourceName, destinationTap])
                    if res.exitCode != 0 {
                        failure = failureMessage(for: res)
                    } else {
                        let lastComponent = sourceName.split(separator: "/").last.map(String.init) ?? sourceName
                        let formulaName = extractedFormulaName(from: res.stdout,
                                                               fallbackBase: baseFormulaName(lastComponent),
                                                               fallbackVersion: ver)
                        // Unlink before installing so the new keg's symlinks don't
                        // collide with a currently linked keg of the same product.
                        for keg in versionFamily(of: item, in: items).filter({ $0.linkedVersion != nil }) {
                            let unlinkRes = try await runner.run(["unlink", "--formula", keg.fullName])
                            if unlinkRes.exitCode != 0 { failure = failureMessage(for: unlinkRes); break }
                        }
                        if failure == nil {
                            let installRes = try await runner.run(["install", "-y", "\(destinationTap)/\(formulaName)"])
                            if installRes.exitCode != 0 { failure = failureMessage(for: installRes) }
                        }
                    }
                }
            }
        } catch {
            failure = "brew command failed: \(error.localizedDescription)"
        }
        tapAction = failure.map { .failed(action: action, message: $0) } ?? .idle
        await performLoadTaps()
        await performRefresh(forceManifest: true)
    }

    /// Brew's formula/cask disambiguation flag (trust, pin, unpin all take it).
    private static func kindFlag(_ kind: BrewItem.Kind) -> String {
        kind == .formula ? "--formula" : "--cask"
    }

    // MARK: - Preview (packages this machine has not installed)

    /// A preview read failed; `message` is brew's own wording (verbatim refusal
    /// when it refused), ready to display without re-wrapping.
    public struct PreviewError: Error, Equatable { public let message: String }

    /// `brew info --json=v2 <tap>/<name>` answers for not-installed packages from the
    /// tap definition / its API data without installing anything (verified 2026-10-30).
    /// For an item whose tap is untrusted, brew refuses with its own wording and names
    /// the `brew trust` fix (§22) — the GUI surfaces that verbatim and offers the Trust action.
    public func fetchPreview(qualified: String, kind: BrewItem.Kind) async -> Result<BrewItem, PreviewError> {
        if let refresh = refreshTask { await refresh.value }   // never race our own brews
        if let upgrade = upgradeTask { await upgrade.value }
        if let action = tapActionTask { await action.value }
        var args = ["info", "--json=v2"]
        if kind == .cask { args.append("--cask") }
        args.append(qualified)
        do {
            let result = try await runner.run(args)
            guard result.exitCode == 0 else { return .failure(PreviewError(message: failureMessage(for: result))) }
            let snapshot = try InfoSnapshot.decode(result.stdout)
            guard let item = InventoryMerger.preview(from: snapshot, kind: kind, greedy: settings.greedyOutdated) else {
                return .failure(PreviewError(message: "brew reported no \(kind == .formula ? "formula" : "cask") for \(qualified)"))
            }
            return .success(item)
        } catch {
            return .failure(PreviewError(message: "brew command failed: \(error.localizedDescription)"))
        }
    }

    private func parseTapNameError(_ raw: String) -> String {
        if case .failure(let problem) = parseTapName(raw) { return problem.message }
        return "invalid tap name"
    }

    private func runTapAction(_ action: TapAction, args: [String], reloadInventory: Bool) async {
        if let existing = tapActionTask { await existing.value; return } // one mutation at a time
        if let refresh = refreshTask { await refresh.value }
        if let upgrade = upgradeTask { await upgrade.value }
        if brewProbe.isBrewRunningExternally() {
            tapAction = .failed(action: action, message: "brew is busy (another brew process is running) — wait for it, then retry")
            return
        }
        let task = Task { await self.performTapAction(action, args: args, reloadInventory: reloadInventory) }
        tapActionTask = task
        await task.value
        tapActionTask = nil
    }

    private func performTapAction(_ action: TapAction, args: [String], reloadInventory: Bool) async {
        tapAction = .running(action)
        do {
            let result = try await runner.run(args)
            guard result.exitCode == 0 else {
                tapAction = .failed(action: action, message: failureMessage(for: result))
                return
            }
            tapAction = .idle
            // Every mutation can move the trust store: trust/untrust directly, and an
            // install because a fully-qualified install auto-trusts the item (§22).
            // performLoadTaps ends with performLoadTrust, so the store re-reads with the taps.
            await performLoadTaps()
            // Tapping/untapping changes which packages exist and where they came from.
            if reloadInventory { await performRefresh(forceManifest: true) }
        } catch {
            tapAction = .failed(action: action, message: "brew command failed: \(error.localizedDescription)")
        }
    }

    private func performLoadTaps() async {
        tapsState = .loading
        do {
            if jqAvailable {
                let result = try await runner.run(["tap-info", "--installed", "--json"])
                guard result.exitCode == 0 else { failTaps(message: failureMessage(for: result)); return }
                taps = sortedTapsForDisplay(try TapInfo.decode(result.stdout))
                tapsNamesOnly = false
            } else {
                // No jq → the app never asks brew for JSON (same posture as list/info).
                let result = try await runner.run(["tap"])
                guard result.exitCode == 0 else { failTaps(message: failureMessage(for: result)); return }
                taps = sortedTapsForDisplay(parseTapNames(String(decoding: result.stdout, as: UTF8.self))
                    .map(TapInfo.init(name:)))
                tapsNamesOnly = true
            }
            tapsUpdated = Date()
            tapsState = .ready
            await performLoadTrust()
        } catch {
            failTaps(message: "brew command failed: \(error.localizedDescription)")
        }
    }

    /// `brew trust --json=v1` — per-item grants. Not gated on jqAvailable: brew emits
    /// this JSON without jq (verified 2026-10-30 with jq off PATH; the CLI pretty-prints
    /// it in Ruby, unlike list/info — §22). A failed read leaves the store unknown;
    /// the tap pane then hides per-item trust buttons rather than guessing a state.
    private func performLoadTrust() async {
        do {
            let result = try await runner.run(["trust", "--json=v1"])
            trustStore = result.exitCode == 0 ? try? TrustStore.decode(result.stdout) : nil
        } catch {
            trustStore = nil
        }
    }

    // MARK: - Brew (top 30-day installs)

    /// The Brew pane's top-installs list, loaded lazily like taps: pure HTTP
    /// against formulae.brew.sh (no brew command, no inventory coupling), so it
    /// never gates or is gated by a refresh. Fetched once per launch; only the
    /// pane's Refresh button re-fetches. A failed fetch keeps the last good
    /// list so stale-beating-empty never happens after a first success.
    public func loadTopInstalls(period: AnalyticsPeriod, force: Bool = false) async {
        if let existing = topInstallsTask { await existing.value; return } // single flight
        if !force, topInstalls[period] != nil { return }
        let task = Task { await self.performLoadTopInstalls(period: period, force: force) }
        topInstallsTask = task
        await task.value
        topInstallsTask = nil
    }

    private func performLoadTopInstalls(period: AnalyticsPeriod, force: Bool) async {
        topInstallsState = .loading
        do {
            topInstalls[period] = try await topInstallsFetcher.fetchTopInstalls(now: Date(), limit: 10, period: period, force: force)
            topInstallsState = .ready
        } catch {
            topInstallsState = .failed(message: "analytics fetch failed: \(error.localizedDescription)")
        }
    }

    private func failTaps(message: String) {
        tapsState = .failed(message: message)
    }

    /// Recompute badges after a settings change (greedy toggle) using the
    /// last fetched manifest — no brew commands re-run.
    public func settingsChanged() {
        guard !items.isEmpty else { return }
        var current = items
        applyPolicy(to: &current, manifest: manifest)
        items = current
    }

    private func applyPolicy(to merged: inout [BrewItem], manifest: PackageManifest?) {
        for i in merged.indices {
            merged[i].latestVersion = latestVersion(for: merged[i], manifest: manifest)
            merged[i].outdated = outdatedState(item: merged[i], manifest: manifest, greedy: settings.greedyOutdated)
        }
    }

    private func fail(message: String) {
        state = .failed(message: message)
        lastFailure = Date()
    }

    private func failureMessage(for result: BrewResult) -> String {
        let text = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var message = text.isEmpty ? "brew exited with status \(result.exitCode)" : (text.count > 300 ? "…" + text.suffix(300) : text)
        if brewProbe.isBrewRunningExternally() { message += " — brew is busy (another brew process is running)" }
        return message
    }
}
