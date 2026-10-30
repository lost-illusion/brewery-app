import Foundation
import Testing
@testable import BreweryCore

// MARK: - Fakes

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let results: [String: BrewResult]
    private(set) var calls: [[String]] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var infoEntered = false

    private let gateInfo: Bool
    init(results: [String: BrewResult], gateInfo: Bool = false) {
        self.results = results
        self.gateInfo = gateInfo
    }

    func run(_ args: [String]) async throws -> BrewResult {
        calls.append(args)
        await Task.yield()
        if args.first == "info", gateInfo { // gate only when armed, so other tests' info calls return
            infoEntered = true
            entryWaiter?.resume(); entryWaiter = nil
            await withCheckedContinuation { cont in gate = cont }
        }
        guard let r = results[args.joined(separator: " ")] else {
            return BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted args: \(args)".utf8))
        }
        return r
    }

    func waitForInfoEntry() async {
        if infoEntered { return }
        await withCheckedContinuation { cont in entryWaiter = cont }
    }

    func resumeInfoGate() { gate?.resume(); gate = nil }
}

private struct FakeProbe: ExternalBrewProbing {
    let running: Bool
    func isBrewRunningExternally() -> Bool { running }
}

private final class FakeManifestFetcher: ManifestFetching, @unchecked Sendable {
    let manifest: PackageManifest
    let fetchedAt: Date
    private(set) var forceSeen: [Bool] = []
    init(manifest: PackageManifest, fetchedAt: Date) {
        self.manifest = manifest
        self.fetchedAt = fetchedAt
    }
    func fetch(bottleTag: String, now: Date, force: Bool) async throws -> ManifestFetchResult {
        forceSeen.append(force)
        return ManifestFetchResult(manifest: manifest, fetchedAt: fetchedAt)
    }
}

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    let response: Data
    var calls: [URL] = []
    init(response: Data) { self.response = response }
    func data(from url: URL) async throws -> Data { calls.append(url); return response }
}

// MARK: - Harness

private func ok(_ data: Data) -> BrewResult { BrewResult(exitCode: 0, stdout: data, stderr: Data()) }

private struct Harness {
    let model: InventoryModel
    let runner: FakeRunner
    let store: SnapshotStore
}

@MainActor
private func makeHarness(probeRunning: Bool = false, jqAvailable: Bool = true,
                         listResult: BrewResult? = nil, gateInfo: Bool = false,
                         extraResults: [String: BrewResult] = [:],
                         manifestFetcher: ManifestFetching? = nil) throws -> Harness {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var results: [String: BrewResult] = [
        "list --json --versions": listResult ?? ok(fixtureData("list.json")),
        "info --json=v2 --installed": ok(fixtureData("info.json")),
        "list --versions": ok(fixtureData("text-list-real.txt")),
    ]
    results.merge(extraResults) { _, new in new }
    let runner = FakeRunner(results: results, gateInfo: gateInfo)
    let http = FakeHTTP(response: fixtureData("manifest-mini.json"))
    let model = InventoryModel(runner: runner,
                               manifestFetcher: manifestFetcher ?? ManifestFetcher(http: http,
                                   cacheURL: dir.appendingPathComponent("manifest-cache.json")),
                               store: SnapshotStore(directory: dir),
                               brewProbe: FakeProbe(running: probeRunning),
                               jqAvailable: jqAvailable,
                               settings: InventorySettings())
    return Harness(model: model, runner: runner, store: SnapshotStore(directory: dir))
}

// MARK: - Tests

@MainActor
@Test func model_forceManifestFlagReachesFetcher() async throws {
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-mini.json"))
    let fake = FakeManifestFetcher(manifest: manifest,
                                   fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let h = try makeHarness(manifestFetcher: fake)
    await h.model.refresh(reason: .manual)
    await h.model.refresh(reason: .manual, forceManifest: true)
    #expect(fake.forceSeen == [false, true]) // plain refresh never forces; the force flag plumbs through
}

@MainActor
@Test func model_versionDataAsOfUsesManifestFetchedAt() async throws {
    // The footer must show when the version data was really fetched — a manifest
    // served from cache is NOT "as of now".
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-mini.json"))
    let h = try makeHarness(manifestFetcher: FakeManifestFetcher(manifest: manifest, fetchedAt: older))
    await h.model.refresh(reason: .manual)
    #expect(h.model.versionDataAsOf == older)
}

@MainActor
@Test func model_degradedTextFallbackRoutesCaskRows() async throws {
    // brew list --versions includes casks; degraded (jq-missing) mode must fetch
    // them as casks, not silently mislabel them as formulae.
    let h = try makeHarness(jqAvailable: false, extraResults: [
        "list --cask --versions": ok(Data("wireshark-app 4.6.9\n".utf8)),
    ])
    await h.model.refresh(reason: .manual)
    let rows = h.model.items.filter { $0.name == "wireshark-app" }
    #expect(rows.count == 1) // not duplicated as formula + cask
    #expect(rows.first?.kind == .cask)
}

@Test @MainActor func model_manual_refresh_mergesAndAppliesPolicy() async throws {
    let h = try makeHarness()
    await h.model.refresh(reason: .manual)
    #expect(h.model.state == .ready)
    let ralphex = try #require(h.model.items.first { $0.name == "ralphex" })
    #expect(ralphex.sourceState == .listOnly(reason: InventoryMerger.listOnlyReason))
    let ace = try #require(h.model.items.first { $0.name == "ace" })
    #expect(ace.outdated == .upToDate) // manifest-mini has ace 8.0.8 == installed
    #expect(ace.latestVersion == "8.0.8")
    #expect(h.model.versionDataAsOf != nil)
    #expect(h.model.inventoryUpdated != nil)
    #expect(h.store.loadLatest(.listJSON)?.data == fixtureData("list.json"))
    #expect(h.store.loadLatest(.infoJSON)?.data == fixtureData("info.json"))
}

@Test @MainActor func model_focusRefreshDeferredWhileExternalBrewRunning() async throws {
    let h = try makeHarness(probeRunning: true)
    await h.model.refresh(reason: .focus)
    #expect(h.runner.calls.isEmpty) // Review Focus 4: never touch a busy brew on focus
    #expect(h.model.items.isEmpty)
    #expect(h.model.state == .idle)
}

@Test @MainActor func model_manualRefreshDuringExternalBrewSurfacesBrewError() async throws {
    let busy = BrewResult(exitCode: 1, stdout: Data(),
                          stderr: Data("Error: Cannot lock /opt/homebrew/var/homebrew/lock".utf8))
    let h = try makeHarness(probeRunning: true, listResult: busy)
    await h.model.refresh(reason: .manual)
    switch h.model.state {
    case .failed(let message):
        #expect(message.contains("Cannot lock"))
        #expect(message.contains("brew is busy"))
    default:
        Issue.record("expected .failed, got \(h.model.state)")
    }
}

@Test @MainActor func model_focusRefreshBacksOff60sAfterFailure() async throws {
    let broken = BrewResult(exitCode: 1, stdout: Data(), stderr: Data("Error: boom".utf8))
    let h = try makeHarness(listResult: broken)
    await h.model.refresh(reason: .manual)
    if case .failed = h.model.state { } else { Issue.record("expected .failed, got \(h.model.state)") }
    let callsAfterFailure = h.runner.calls.count
    await h.model.refresh(reason: .focus) // probe is false; the 60 s failure backoff must block it
    #expect(h.runner.calls.count == callsAfterFailure)
}

@Test @MainActor func model_singleFlight() async throws {
    let h = try makeHarness()
    let model = h.model // capture only the Sendable model in the child tasks
    async let a: Void = model.refresh(reason: .manual)
    async let b: Void = model.refresh(reason: .manual)
    await (a, b)
    let listCalls = h.runner.calls.filter { $0.first == "list" }
    #expect(listCalls.count == 1)
    #expect(h.model.state == .ready)
}

@Test @MainActor func model_degradedTextFallbackWhenJqMissing() async throws {
    let h = try makeHarness(jqAvailable: false)
    await h.model.refresh(reason: .manual)
    #expect(h.runner.calls == [["list", "--versions"], ["list", "--cask", "--versions"]]) // no --json asked of brew when jq is missing; casks fetched separately
    let ralphex = try #require(h.model.items.first { $0.name == "ralphex" })
    #expect(ralphex.sourceState == .listOnly(reason: InventoryMerger.listOnlyReason))
    #expect(h.model.state == .ready)
    #expect(h.model.versionDataAsOf == nil) // no info → no bottleTag → manifest step skipped
    #expect(h.store.loadLatest(.textList)?.data == fixtureData("text-list-real.txt"))
}

@Test @MainActor func model_listRowsPublishBeforeInfo() async throws {
    let h = try makeHarness(gateInfo: true)
    let task = Task { await h.model.refresh(reason: .manual) }
    await h.runner.waitForInfoEntry()
    for _ in 0..<100 where h.model.items.count < 5 { await Task.yield() }
    #expect(h.model.items.count == 5) // list.json rows: 2 formulae + 3 casks, published early
    #expect(h.model.items.allSatisfy { if case .listOnly = $0.sourceState { true } else { false } })
    h.runner.resumeInfoGate()
    await task.value
    let ace = try #require(h.model.items.first { $0.name == "ace" })
    #expect(ace.sourceState == .complete) // info merged in after the gate
}

// MARK: - Upgrade actions

@MainActor
@Test func model_upgradeAll_runsUpdateThenUpgradeThenRefresh() async throws {
    let h = try makeHarness(extraResults: [
        "update": ok(Data("Already up-to-date.\n".utf8)),
        "upgrade -y": ok(Data("Upgraded.\n".utf8)),
    ])
    await h.model.upgradeAll()
    #expect(h.model.upgrade == .idle)
    #expect(h.model.state == .ready) // badges refreshed after a successful upgrade
    #expect(h.runner.calls.first == ["update"]) // explicit update: brew upgrade consults brew's own cache
    #expect(h.runner.calls.contains(["upgrade", "-y"])) // -y: brew's ask mode would hang the GUI (§77)
    let listCalls = h.runner.calls.filter { $0.first == "list" }
    #expect(listCalls.count == 1) // the post-upgrade re-read (no pre-upgrade refresh in this test)
    #expect(h.runner.calls.last?.first == "info")
}

@MainActor
@Test func model_upgradeAllGreedyAddsGreedyFlag() async throws {
    let h = try makeHarness(extraResults: [
        "update": ok(Data()),
        "upgrade -y --greedy": ok(Data()),
    ])
    h.model.settings.greedyOutdated = true
    await h.model.upgradeAll()
    #expect(h.runner.calls.contains(["upgrade", "-y", "--greedy"])) // greedy list ⇒ greedy command (§70)
    #expect(!h.runner.calls.contains(["upgrade", "-y"]))
    #expect(h.model.upgrade == .idle)
}

@MainActor
@Test func model_upgradeSingleTargetsFullName() async throws {
    let h = try makeHarness(extraResults: [
        "update": ok(Data()),
        "upgrade -y ace": ok(Data()),
    ])
    await h.model.refresh(reason: .manual)
    let ace = try #require(h.model.items.first { $0.name == "ace" })
    await h.model.upgrade(ace)
    #expect(h.runner.calls.contains(["upgrade", "-y", "ace"]))
    #expect(h.model.upgrade == .idle)
}

@MainActor
@Test func model_upgradeSelfUpdatingCaskAddsGreedy() async throws {
    // wireshark-app has auto_updates true: only --greedy makes brew touch it (§70).
    let h = try makeHarness(extraResults: [
        "update": ok(Data()),
        "upgrade -y --greedy wireshark-app": ok(Data()),
    ])
    h.model.settings.greedyOutdated = true
    await h.model.refresh(reason: .manual)
    let wireshark = try #require(h.model.items.first { $0.name == "wireshark-app" })
    #expect(wireshark.outdated == .selfUpdating(latestKnown: "4.6.9"))
    await h.model.upgrade(wireshark)
    #expect(h.runner.calls.contains(["upgrade", "-y", "--greedy", "wireshark-app"]))
}

@MainActor
@Test func model_upgradeUpdateStepFailureStopsBeforeUpgrade() async throws {
    let broken = BrewResult(exitCode: 1, stdout: Data(), stderr: Data("Error: pull failed".utf8))
    let h = try makeHarness(extraResults: ["update": broken])
    await h.model.upgradeAll()
    switch h.model.upgrade {
    case .failed(let message): #expect(message.contains("pull failed"))
    default: Issue.record("expected .failed, got \(h.model.upgrade)")
    }
    #expect(h.runner.calls == [["update"]]) // no upgrade attempted after a failed brew update
    #expect(h.model.state == .idle) // upgrade failure is not a refresh failure
}

@MainActor
@Test func model_upgradeRefusedWhileExternalBrewRunning() async throws {
    let h = try makeHarness(probeRunning: true)
    await h.model.upgradeAll()
    switch h.model.upgrade {
    case .failed(let message): #expect(message.contains("brew is busy"))
    default: Issue.record("expected .failed, got \(h.model.upgrade)")
    }
    #expect(h.runner.calls.isEmpty) // never contend with a brew we did not start
}

@Test func store_roundTripSaveLoad() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SnapshotStore(directory: dir)
    #expect(store.loadLatest(.listJSON) == nil)
    let payload = Data(#"{"formulae":[],"casks":[]}"#.utf8)
    try store.save(payload, kind: .listJSON)
    let loaded = try #require(store.loadLatest(.listJSON))
    #expect(loaded.data == payload)
    #expect(abs(loaded.savedAt.timeIntervalSinceNow) < 60)
}
