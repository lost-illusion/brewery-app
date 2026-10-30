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
    public var settings: InventorySettings

    private let runner: CommandRunning
    private let manifestFetcher: ManifestFetching
    private let store: SnapshotStore
    private let brewProbe: ExternalBrewProbing
    private let jqAvailable: Bool

    private var refreshTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var lastFailure: Date?
    private var lastManifest: PackageManifest?
    private static let failureBackoff: TimeInterval = 60

    public init(runner: CommandRunning, manifestFetcher: ManifestFetching, store: SnapshotStore,
                brewProbe: ExternalBrewProbing, jqAvailable: Bool, settings: InventorySettings) {
        self.runner = runner
        self.manifestFetcher = manifestFetcher
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
            lastManifest = manifest
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

    /// Recompute badges after a settings change (greedy toggle) using the
    /// last fetched manifest — no brew commands re-run.
    public func settingsChanged() {
        guard !items.isEmpty else { return }
        var current = items
        applyPolicy(to: &current, manifest: lastManifest)
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
