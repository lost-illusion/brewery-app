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
    func fetch(bottleTag: String, now: Date) async throws -> ManifestFetchResult
}

extension ManifestFetcher: ManifestFetching {}

@MainActor
@Observable
public final class InventoryModel {
    public enum ViewState: Equatable { case idle, loading, ready, failed(message: String) }

    public private(set) var items: [BrewItem] = []
    public private(set) var state: ViewState = .idle
    public private(set) var inventoryUpdated: Date?
    public private(set) var versionDataAsOf: Date?
    public var settings: InventorySettings

    private let runner: CommandRunning
    private let manifestFetcher: ManifestFetching
    private let store: SnapshotStore
    private let brewProbe: ExternalBrewProbing
    private let jqAvailable: Bool

    private var refreshTask: Task<Void, Never>?
    private var lastFailure: Date?
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

    public func refresh(reason: RefreshReason) async {
        if let existing = refreshTask { await existing.value; return } // single flight
        if reason == .focus, focusGateBlocks(now: Date()) { return }
        let task = Task { await self.performRefresh() }
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

    private func performRefresh() async {
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
                // brew needs jq to emit --json; without it the plain-text form is the fallback (§43)
                let rows = parseTextListVersions(String(decoding: listRes.stdout, as: UTF8.self))
                listSnapshot = ListSnapshot(
                    formulae: rows.map { ListSnapshot.FormulaItem(name: $0.name, versions: $0.versions,
                                                                 linkedVersion: nil, optlinkedVersion: nil, pinnedVersion: nil) },
                    casks: [])
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
                manifest = try? await manifestFetcher.fetch(bottleTag: bottleTag, now: now).manifest
                versionDataAsOf = manifest != nil ? now : nil
            } else {
                versionDataAsOf = nil // no info → no bottleTag → manifest step skipped
            }
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
