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
        "trust --json=v1": ok(fixtureData("trust.json")),
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
    #expect(runner.calls == [["tap-info", "--installed", "--json"], ["trust", "--json=v1"]]) // one tap read + one trust read
    await model.loadTaps(force: true)
    #expect(runner.calls.count == 4)
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
    // trust --json is the one JSON brew emits without jq (verified 2026-10-30, §22),
    // so the no-jq path still reads per-item trust state.
    #expect(runner.calls == [["tap"], ["trust", "--json=v1"]])
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

// MARK: - Item-level trust & install (compat §22)

@MainActor
@Test func trustStore_loadsWithTaps() async {
    let (model, _) = makeHarness()
    #expect(model.trustStore == nil) // unknown until the taps pane asks
    await model.loadTaps()
    #expect(model.trustStore?.isTrusted(qualified: "umputun/apps/revdiff", kind: .formula) == true)
    #expect(model.trustStore?.isTrusted(qualified: "umputun/apps/cronn", kind: .formula) == false)
}

@MainActor
@Test func itemTrust_usesFormulaFlagThenReReadsTrustStore() async {
    let granted = """
    {"taps":[],"formulae":["umputun/apps/cronn"],"casks":[],"commands":[]}
    """
    let (model, runner) = makeHarness(tapResults: [
        "trust --formula umputun/apps/cronn": ok("Trusted formula: umputun/apps/cronn\n"),
        "trust --json=v1": ok(granted),
    ])
    await model.trustItem(qualified: "umputun/apps/cronn", kind: .formula)
    #expect(runner.calls.first == ["trust", "--formula", "umputun/apps/cronn"])
    #expect(model.tapAction == .idle)
    // re-read after the mutation, so row buttons show the new grant without a manual refresh
    #expect(runner.calls.filter { $0 == ["trust", "--json=v1"] }.count == 1)
    #expect(model.trustStore?.isTrusted(qualified: "umputun/apps/cronn", kind: .formula) == true)
    // trusted rows change shape once info sees them (§43), so the inventory reloads too
    #expect(runner.calls.contains { $0.first == "list" })
}

@MainActor
@Test func itemUntrust_usesCaskFlagForCasks() async {
    let (model, runner) = makeHarness(tapResults: ["untrust --cask umputun/apps/agterm": ok("Untrusted cask: agterm\n")])
    await model.untrustItem(qualified: "umputun/apps/agterm", kind: .cask)
    #expect(runner.calls.first == ["untrust", "--cask", "umputun/apps/agterm"])
    #expect(model.tapAction == .idle)
}

@MainActor
@Test func itemInstall_runsBrewInstallAndReloadsInventory() async {
    // qualified install from an untrusted tap: brew auto-trusts the item itself (§22);
    // -y because ask mode is brew's install default and would hang the GUI (§77)
    let (model, runner) = makeHarness(tapResults: ["install -y umputun/apps/mpt": ok("==> Pouring mpt bottle\n")])
    await model.installItem("umputun/apps/mpt")
    #expect(runner.calls.first == ["install", "-y", "umputun/apps/mpt"])
    #expect(model.tapAction == .idle)
    #expect(runner.calls.contains { $0.first == "list" }) // the new package must appear in the inventory
}

@MainActor
@Test func itemActions_refusedWhileExternalBrewRunning() async {
    let (model, runner) = makeHarness(probeRunning: true)
    await model.installItem("umputun/apps/mpt")
    if case .failed(let action, let message) = model.tapAction {
        #expect(action == .installing(qualified: "umputun/apps/mpt"))
        #expect(message.contains("brew is busy"))
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
    #expect(runner.calls.filter { $0.first == "install" }.isEmpty)
}

// MARK: - Pin / unpin (compat §93)

@MainActor
@Test func itemPin_runsBrewPinWithKindFlagAndReloadsInventory() async {
    let (model, runner) = makeHarness(tapResults: ["pin --formula wget": ok("Pinned wget\n")])
    await model.pinItem(qualified: "wget", kind: .formula)
    #expect(runner.calls.first == ["pin", "--formula", "wget"])
    #expect(model.tapAction == .idle)
    // the pinned flag comes back via the info JSON and drives the Pinned
    // section + Update buttons, so the inventory must re-read
    #expect(runner.calls.contains { $0.first == "list" })
}

@MainActor
@Test func itemUnpin_usesCaskFlagForCasks() async {
    let (model, runner) = makeHarness(tapResults: ["unpin --cask wireshark-app": ok("Unpinned wireshark-app\n")])
    await model.unpinItem(qualified: "wireshark-app", kind: .cask)
    #expect(runner.calls.first == ["unpin", "--cask", "wireshark-app"])
    #expect(model.tapAction == .idle)
}

@MainActor
@Test func itemPin_surfacesBrewsRefusalVerbatim() async {
    // brew's real wording for a name it will not pin (not installed)
    let (model, runner) = makeHarness(tapResults: ["pin --formula nope": fail("Error: Formula 'nope' is not installed.")])
    await model.loadTaps()
    await model.pinItem(qualified: "nope", kind: .formula)
    if case .failed(let action, let message) = model.tapAction {
        #expect(action == .pinning(qualified: "nope"))
        #expect(message.contains("not installed"))
    } else {
        Issue.record("expected .failed, got \(model.tapAction)")
    }
    #expect(runner.calls.filter { $0.first == "list" }.isEmpty) // failed mutation: no inventory re-read
}

// MARK: - Preview of not-installed packages (compat §22)

@MainActor
@Test func preview_buildsItemFromTargetedInfoJSON() async {
    let (model, runner) = makeHarness(tapResults: [
        "info --json=v2 umputun/apps/revdiff": ok(fixtureData("info-preview.json")),
    ])
    let result = await model.fetchPreview(qualified: "umputun/apps/revdiff", kind: .formula)
    guard case .success(let item) = result else {
        Issue.record("expected .success, got \(result)")
        return
    }
    #expect(runner.calls == [["info", "--json=v2", "umputun/apps/revdiff"]])
    #expect(item.fullName == "umputun/apps/revdiff")
    #expect(item.tap == "umputun/apps")
    #expect(item.latestVersion == "1.13.0")       // versions.stable of the definition
    #expect(item.installedVersions.isEmpty)       // preview: nothing installed locally
    #expect(item.outdated == nil)                 // not installed → nothing to compare
    #expect(item.sourceState == .complete)
}

@MainActor
@Test func preview_installedRowCarriesFactsAndBrewsOutdatedVerdict() async {
    // tap packages are absent from the core manifest, so the preview takes
    // brew's own `outdated` boolean as the authority (§22)
    let installedJSON = """
    {"formulae":[{"name":"revdiff","full_name":"umputun/apps/revdiff","tap":"umputun/apps",
      "desc":"TUI","homepage":"https://github.com/umputun/revdiff",
      "versions":{"stable":"1.14.0"},
      "installed":[{"version":"1.13.0","time":1730000000}],"linked_keg":"1.13.0",
      "pinned":false,"outdated":true,"deprecated":false,"disabled":false,
      "keg_only":false,"dependencies":[]}],"casks":[]}
    """
    let (model, _) = makeHarness(tapResults: ["info --json=v2 umputun/apps/revdiff": ok(installedJSON)])
    let result = await model.fetchPreview(qualified: "umputun/apps/revdiff", kind: .formula)
    guard case .success(let item) = result else {
        Issue.record("expected .success, got \(result)")
        return
    }
    #expect(item.installedVersions == ["1.13.0"])
    #expect(item.linkedVersion == "1.13.0")
    #expect(item.latestVersion == "1.14.0")
    #expect(item.outdated == .updateAvailable(latest: "1.14.0"))
    #expect(item.installedAt != nil)
}

@MainActor
@Test func preview_caskAddsCaskFlag() async {
    let caskJSON = """
    {"formulae":[],"casks":[{"token":"agterm","tap":"umputun/apps","version":"0.3.0",
      "desc":"Terminal on libghostty","homepage":"https://github.com/umputun/agterm","auto_updates":true}]}
    """
    let (model, runner) = makeHarness(tapResults: ["info --json=v2 --cask umputun/apps/agterm": ok(caskJSON)])
    let result = await model.fetchPreview(qualified: "umputun/apps/agterm", kind: .cask)
    guard case .success(let item) = result else {
        Issue.record("expected .success, got \(result)")
        return
    }
    #expect(runner.calls.first == ["info", "--json=v2", "--cask", "umputun/apps/agterm"])
    #expect(item.kind == .cask)
    #expect(item.latestVersion == "0.3.0")
    #expect(item.autoUpdates == true)
}

@MainActor
@Test func preview_selfUpdatingCaskFollowsGreedySetting() async {
    let caskJSON = """
    {"formulae":[],"casks":[{"token":"agterm","tap":"umputun/apps","version":"1.0.0",
      "installed":"1.0.0","installed_time":1730000000,"outdated":false,"pinned":false,
      "deprecated":false,"disabled":false,"auto_updates":true}]}
    """
    let (model, _) = makeHarness(tapResults: ["info --json=v2 --cask umputun/apps/agterm": ok(caskJSON)])
    let quiet = await model.fetchPreview(qualified: "umputun/apps/agterm", kind: .cask)
    guard case .success(let item) = quiet else { Issue.record("expected .success"); return }
    #expect(item.outdated == .upToDate) // brew-default: self-updating casks are not outdated
    model.settings.greedyOutdated = true
    let greedy = await model.fetchPreview(qualified: "umputun/apps/agterm", kind: .cask)
    guard case .success(let greedyItem) = greedy else { Issue.record("expected .success"); return }
    #expect(greedyItem.outdated == .selfUpdating(latestKnown: "1.0.0")) // matches the inventory policy (§70)
}

@MainActor
@Test func preview_untrustedItemSurfacesBrewsRefusalVerbatim() async {
    // brew's real refusal (reproduced 2026-10-30 on this machine, compat §22)
    let refusal = fail("""
    Error: Refusing to load formula umputun/apps/cronn from untrusted tap umputun/apps.
    Run `brew trust --formula umputun/apps/cronn` or `brew trust umputun/apps` to trust it.
    """)
    let (model, _) = makeHarness(tapResults: ["info --json=v2 umputun/apps/cronn": refusal])
    let result = await model.fetchPreview(qualified: "umputun/apps/cronn", kind: .formula)
    guard case .failure(let error) = result else {
        Issue.record("expected .failure, got .success")
        return
    }
    #expect(error.message.contains("Refusing to load formula")) // brew's own wording, names the fix
    #expect(error.message.contains("brew trust --formula"))
}
