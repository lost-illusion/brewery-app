import Foundation
import Testing
@testable import BreweryCore

// MARK: - Fakes

private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    private let results: [String: BrewResult]
    private(set) var calls: [[String]] = []
    init(results: [String: BrewResult]) { self.results = results }

    func run(_ args: [String]) async throws -> BrewResult {
        calls.append(args)
        await Task.yield()
        guard let result = results[args.joined(separator: " ")] else {
            return BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted args: \(args)".utf8))
        }
        return result
    }
}

private struct FakeProbe: ExternalBrewProbing {
    let running: Bool
    func isBrewRunningExternally() -> Bool { running }
}

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    let response: Data
    init(response: Data) { self.response = response }
    func data(from url: URL) async throws -> Data { response }
}

private func ok(_ data: Data = Data()) -> BrewResult { BrewResult(exitCode: 0, stdout: data, stderr: Data()) }
private func ok(_ text: String) -> BrewResult { ok(Data(text.utf8)) }
private func fail(_ text: String) -> BrewResult { BrewResult(exitCode: 1, stdout: Data(), stderr: Data(text.utf8)) }

@MainActor
private func makeHarness(jqAvailable: Bool = true, probeRunning: Bool = false,
                         tapResults: [String: BrewResult] = [:]) -> (InventoryModel, ScriptedRunner) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var results: [String: BrewResult] = [
        "list --json --versions": ok(fixtureData("list.json")),
        "info --json=v2 --installed": ok(fixtureData("info.json")),
        "list --versions": ok(fixtureData("text-list-real.txt")),
        "list --cask --versions": ok(Data("wireshark-app 4.6.9\n".utf8)),
        "tap-info --installed --json": ok(fixtureData("taps.json")),
        "tap": ok(Data("umputun/apps\n".utf8)),
    ]
    results.merge(tapResults) { _, new in new }
    let runner = ScriptedRunner(results: results)
    let model = InventoryModel(runner: runner,
                               manifestFetcher: ManifestFetcher(http: FakeHTTP(response: fixtureData("manifest-mini.json")),
                                   cacheURL: dir.appendingPathComponent("manifest-cache.json")),
                               store: SnapshotStore(directory: dir),
                               brewProbe: FakeProbe(running: probeRunning),
                               jqAvailable: jqAvailable, settings: InventorySettings())
    return (model, runner)
}

// MARK: - Loading

@MainActor
@Test func taps_loadLazilyOnceThenOnlyOnForce() async {
    let (model, runner) = makeHarness()
    await model.loadTaps()
    await model.loadTaps()
    #expect(runner.calls == [["tap-info", "--installed", "--json"]]) // one call, not two
    await model.loadTaps(force: true)
    #expect(runner.calls.count == 2)
    #expect(model.tapsState == .ready)
    #expect(model.tapsNamesOnly == false)
}

@MainActor
@Test func taps_externalOrderAndFields() async {
    let (model, _) = makeHarness()
    await model.loadTaps()
    #expect(model.taps.map(\.name) == ["umputun/apps", "homebrew/cask", "homebrew/core"])
    let external = model.taps.filter(\.isExternal)
    #expect(external.count == 1) // sidebar badge: third-party taps only
    #expect(model.taps.first?.trusted == false)
}

@MainActor
@Test func taps_withoutJqFallBackToNamesOnly() async {
    let (model, runner) = makeHarness(jqAvailable: false)
    await model.loadTaps()
    #expect(runner.calls == [["tap"]]) // never asks brew for JSON it cannot parse
    #expect(model.tapsNamesOnly)
    #expect(model.taps.map(\.name) == ["umputun/apps"])
    #expect(model.taps.first?.availableCount == 0)
}

@MainActor
@Test func taps_failureKeepsInventoryStateSeparate() async {
    let (model, _) = makeHarness(tapResults: ["tap-info --installed --json": fail("Error: no taps")])
    await model.loadTaps()
    if case .failed(let message) = model.tapsState {
        #expect(message.contains("no taps"))
    } else {
        Issue.record("expected tapsState .failed, got \(model.tapsState)")
    }
    #expect(model.state == .idle) // a tap read failure is not an inventory failure
}

// MARK: - Mutations

@MainActor
@Test func tapAdd_runsTapThenReloadsTapsAndInventory() async {
    let (model, runner) = makeHarness(tapResults: ["tap umputun/other": ok("Tapped.\n")])
    await model.addTap(name: "umputun/other", remote: nil)
    #expect(model.tapAction == .idle)
    #expect(runner.calls.first == ["tap", "umputun/other"])
    #expect(runner.calls.contains(["tap-info", "--installed", "--json"])) // tap list re-read after the mutation
    #expect(runner.calls.contains(["list", "--json", "--versions"])) // inventory re-read: new packages exist now
}

@MainActor
@Test func tapAdd_customRemoteIsPassedThroughAsTheTwoArgumentForm() async {
    let (model, runner) = makeHarness(tapResults: [
        "tap example/other https://host.example.com/example/homebrew-other.git": ok(),
    ])
    await model.addTap(name: "example/other", remote: "https://host.example.com/example/homebrew-other.git")
    #expect(model.tapAction == .idle)
    #expect(runner.calls.first == ["tap", "example/other", "https://host.example.com/example/homebrew-other.git"])
}

@MainActor
@Test func tapAdd_rejectsBadNamesBeforeTouchingBrew() async {
    let (model, runner) = makeHarness()
    await model.addTap(name: "not-a-tap", remote: nil)
    #expect(runner.calls.isEmpty)
    if case .failed(let action, let message) = model.tapAction {
        #expect(action == .tapping(name: "not-a-tap"))
        #expect(message == "tap names look like user/repo")
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
}

@MainActor
@Test func tapAdd_rejectsRemoteWithoutSchemeBeforeTouchingBrew() async {
    let (model, runner) = makeHarness()
    await model.addTap(name: "example/other", remote: "github.com/example/homebrew-other")
    #expect(runner.calls.isEmpty)
    if case .failed(_, let message) = model.tapAction {
        #expect(message.contains("must start with"))
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
}

@MainActor
@Test func tapRemove_plainUntapAndForceVariant() async {
    let tap = TapInfo(name: "umputun/apps")
    let (model, runner) = makeHarness(tapResults: ["untap umputun/apps": ok("Untapped.\n")])
    await model.removeTap(tap, uninstallingItems: false)
    #expect(runner.calls.first == ["untap", "umputun/apps"])

    let forced = makeHarness(tapResults: ["untap --force umputun/apps": ok("Untapped.\n")])
    await forced.0.removeTap(tap, uninstallingItems: true)
    #expect(forced.1.calls.first == ["untap", "--force", "umputun/apps"]) // --force uninstalls the tap's packages first
    #expect(forced.0.tapAction == .idle)
}

@MainActor
@Test func tapRemove_surfacesBrewsRefusalAndKeepsTheTapListUnchanged() async {
    let tap = TapInfo(name: "umputun/apps")
    // brew's real wording (reproduced 2026-10-30 in a private throwaway prefix, compat §7)
    let refusal = fail("Error: Refusing to untap umputun/apps because it contains installed casks:\n"
                       + "umputun/apps/agterm\numputun/apps/revmux\nUse `brew uninstall --force` to force remove these.")
    let (model, runner) = makeHarness(tapResults: ["untap umputun/apps": refusal])
    await model.loadTaps()
    let before = model.taps.count
    await model.removeTap(tap, uninstallingItems: false)
    if case .failed(let action, let message) = model.tapAction {
        #expect(action == .untapping(name: "umputun/apps"))
        #expect(message.contains("Refusing to untap")) // brew's own wording, verbatim
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
    #expect(model.taps.count == before) // no re-read after a failed mutation
    #expect(runner.calls.filter { $0.first == "tap-info" }.count == 1) // only the initial load
    #expect(model.state == .idle) // and no inventory re-read either
}

@MainActor
@Test func tapTrust_usesTapFlagAndReloadsInventory() async {
    let tap = TapInfo(name: "umputun/apps")
    let (model, runner) = makeHarness(tapResults: ["trust --tap umputun/apps": ok("Trusted.\n")])
    await model.trustTap(tap)
    #expect(runner.calls.first == ["trust", "--tap", "umputun/apps"])
    #expect(model.tapAction == .idle)
    // Trusting a tap is what makes `brew info` report its packages at all, so the
    // rows change shape and must be re-read (§43).
    #expect(runner.calls.contains { $0.first == "list" })

    let untrust = makeHarness(tapResults: ["untrust --tap umputun/apps": ok()])
    await untrust.0.untrustTap(tap)
    #expect(untrust.1.calls.first == ["untrust", "--tap", "umputun/apps"])
}

@MainActor
@Test func tapMutations_refusedWhileExternalBrewRunning() async {
    let tap = TapInfo(name: "umputun/apps")
    let (model, runner) = makeHarness(probeRunning: true)
    await model.addTap(name: "umputun/other", remote: nil)
    if case .failed(_, let message) = model.tapAction {
        #expect(message.contains("brew is busy"))
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
    await model.removeTap(tap, uninstallingItems: true)
    #expect(runner.calls.filter { $0.first == "tap" || $0.first == "untap" }.isEmpty) // never contend with a brew we did not start
}

@MainActor
@Test func tapMutations_areSingleFlight() async {
    let (model, runner) = makeHarness(tapResults: ["tap umputun/one": ok(), "tap umputun/two": ok()])
    async let a: Void = model.addTap(name: "umputun/one", remote: nil)
    async let b: Void = model.addTap(name: "umputun/two", remote: nil)
    await (a, b)
    let taps = runner.calls.filter { $0.first == "tap" }
    #expect(taps.count == 1) // one mutation at a time; the second call joins the first
}
