import Foundation
import Testing
@testable import BreweryCore

// MARK: - Fakes

private func brewItem(_ name: String, tap: String? = "homebrew/core", installed: [String] = [],
                      linked: String? = nil, kegOnly: Bool = false,
                      kind: BrewItem.Kind = .formula) -> BrewItem {
    let fullName: String
    if let tap, tap != "homebrew/core" { fullName = "\(tap)/\(name)" } else { fullName = name }
    return BrewItem(id: fullName, kind: kind, name: name, fullName: fullName, tap: tap,
                    installedVersions: installed, linkedVersion: linked, optlinkedVersion: nil,
                    pinnedVersion: nil, latestVersion: nil, outdated: nil,
                    infoOutdated: nil, infoVersion: nil, isPinned: false,
                    isDeprecated: false, deprecationReason: nil, isDisabled: false, disabledReason: nil,
                    deprecationDate: nil, disableDate: nil, replacementFormula: nil, replacementCask: nil,
                    desc: nil, homepage: nil, installedAt: nil, kegOnly: kegOnly,
                    autoUpdates: false, dependencies: [], sourceState: .complete)
}

private func installedTap(_ name: String) -> TapInfo { TapInfo(name: name) }

/// Virtual API-mode tap: only the decode path reports `installed: false`
/// (`TapInfo(name:)` is the names-only fallback, always installed).
private func virtualTap(_ name: String) -> TapInfo {
    let json = "[{\"name\":\"\(name)\",\"installed\":false}]"
    return try! TapInfo.decode(Data(json.utf8)).first!
}

// MARK: - Name helpers

@Test func sanitizedExtractVersion_mirrorsRubySubGsub() {
    #expect(sanitizedExtractVersion("2.0.14p1") == "2.0.14.1") // strip trailing p1, run → dot
    #expect(sanitizedExtractVersion("v3.5.9") == "3.5.9")      // leading non-digits stripped
    #expect(sanitizedExtractVersion("2023-04-05") == "2023.04.05")
    #expect(sanitizedExtractVersion("1.2") == "1.2")
    #expect(versionedFormulaName(baseName: "umputun/apps/wget", version: "2.0.14p1") == "wget@2.0.14.1")
    #expect(baseFormulaName("openssl@3") == "openssl")
    #expect(baseFormulaName("wget") == "wget")
}

@Test func extractedFormulaName_readsTheWrittenPath_orFallsBack() {
    let out = """
    ==> Searching repository history
    ==> Writing formula for wget at 1.21.1 from revision dead123 to:
    /opt/homebrew/Library/Taps/umputun/homebrew-apps/Formula/wget@1.21.1.rb
    """
    #expect(extractedFormulaName(from: Data(out.utf8), fallbackBase: "wget", fallbackVersion: "1.21.1")
            == "wget@1.21.1")
    // No path line (older brew wording / quiet mode) → the name the GUI planned.
    #expect(extractedFormulaName(from: Data("==> Searching repository history".utf8),
                                fallbackBase: "wget", fallbackVersion: "2.0.14p1") == "wget@2.0.14.1")
}

// MARK: - Plan

@Test func switchPlan_caskIsBlocked() {
    let plan = versionSwitchPlan(for: brewItem("iterm2", kind: .cask), to: "3.4.0",
                                 items: [], taps: [installedTap("umputun/apps")])
    #expect(plan == .blocked(reason: "brew has no versioned casks — a cask install always takes the current version (compat §27)."))
}

@Test func switchPlan_relinksInstalledTargetKeg() {
    let current = brewItem("wget", installed: ["1.25"], linked: "1.25")
    let target = brewItem("wget@1.21.1", tap: "umputun/apps", installed: ["1.21.1"])
    let plan = versionSwitchPlan(for: current, to: "1.21.1",
                                 items: [current, target], taps: [installedTap("umputun/apps")])
    #expect(plan == .relink(linkRack: "umputun/apps/wget@1.21.1", unlinkRacks: ["wget"], kegOnly: false))
}

@Test func switchPlan_relinkCarriesKegOnlyFlagAndSkipsUnlinkWhenNothingLinked() {
    let unlinkedTarget = brewItem("wget@1.21.1", tap: "umputun/apps", installed: ["1.21.1"], kegOnly: true)
    let plan = versionSwitchPlan(for: unlinkedTarget, to: "1.21.1",
                                 items: [unlinkedTarget], taps: [installedTap("umputun/apps")])
    // Nothing else in the family is linked → no unlink step; keg-only targets need
    // brew's own `--force` link flag (cmd/link.rb help).
    #expect(plan == .relink(linkRack: "umputun/apps/wget@1.21.1", unlinkRacks: [], kegOnly: true))
}

@Test func switchPlan_blockedWhenTargetIsAlreadyLinked() {
    let target = brewItem("wget@1.21.1", tap: "umputun/apps", installed: ["1.21.1"], linked: "1.21.1")
    let plan = versionSwitchPlan(for: target, to: "1.21.1",
                                 items: [target], taps: [installedTap("umputun/apps")])
    #expect(plan == .blocked(reason: "1.21.1 is already the linked version."))
}

@Test func switchPlan_extractInstallOnVirtualCoreAsksForCoreClone() {
    let current = brewItem("wget", installed: ["1.25"], linked: "1.25")
    let plan = versionSwitchPlan(for: current, to: "1.21.1", items: [current],
                                 taps: [virtualTap("homebrew/core"), installedTap("umputun/apps")])
    #expect(plan == .extractInstall(sourceName: "wget", version: "1.21.1", sourceTap: "homebrew/core",
                                    destinationCandidates: ["umputun/apps"], needsSourceTapClone: true))
}

@Test func switchPlan_thirdPartySourceExcludesCoreAndItselfAsDestinations() {
    // brew odies "Cannot extract formula to homebrew/core!" and "…to the same tap!"
    // (dev-cmd/extract.rb) — with only those two taps, nothing is left.
    let current = brewItem("mpt", tap: "umputun/apps", installed: ["0.4.0"], linked: "0.4.0")
    let plan = versionSwitchPlan(for: current, to: "0.3.7", items: [current],
                                 taps: [installedTap("umputun/apps"), installedTap("homebrew/core")])
    if case .blocked(let reason) = plan {
        #expect(reason.contains("No tap to extract into"))
    } else {
        Issue.record("expected blocked, got \(plan)")
    }
    // With a real third-party destination it proceeds, fully-qualified source.
    let withHome = versionSwitchPlan(for: current, to: "0.3.7", items: [current],
                                     taps: [installedTap("umputun/apps"), installedTap("other/tap")])
    #expect(withHome == .extractInstall(sourceName: "umputun/apps/mpt", version: "0.3.7",
                                        sourceTap: "umputun/apps", destinationCandidates: ["other/tap"],
                                        needsSourceTapClone: false))
}

@Test func switchPlan_thirdPartySourceNotInTapListIsBlocked() {
    let current = brewItem("mpt", tap: "umputun/apps", installed: ["0.4.0"], linked: "0.4.0")
    let plan = versionSwitchPlan(for: current, to: "0.3.7", items: [current], taps: [installedTap("other/tap")])
    if case .blocked(let reason) = plan {
        #expect(reason.contains("not in the tap list"))
    } else {
        Issue.record("expected blocked, got \(plan)")
    }
}

@Test func switchPlan_thirdPartySourceNotClonedIsBlocked() {
    let current = brewItem("mpt", tap: "umputun/apps", installed: ["0.4.0"], linked: "0.4.0")
    let plan = versionSwitchPlan(for: current, to: "0.3.7", items: [current],
                                 taps: [virtualTap("umputun/apps"), installedTap("other/tap")])
    if case .blocked(let reason) = plan {
        #expect(reason.contains("not cloned on disk"))
    } else {
        Issue.record("expected blocked, got \(plan)")
    }
}

@Test func switchPlan_noUsableDestinationIsBlocked() {
    // Only homebrew/core cloned: brew refuses core, cask and the source tap as destinations.
    let current = brewItem("wget", installed: ["1.25"], linked: "1.25")
    let plan = versionSwitchPlan(for: current, to: "1.21.1", items: [current],
                                 taps: [installedTap("homebrew/core")])
    if case .blocked(let reason) = plan {
        #expect(reason.contains("No tap to extract into"))
    } else {
        Issue.record("expected blocked, got \(plan)")
    }
}

@Test func switchPlan_legacyMultiKegFallsThroughToExtractInstall() {
    // `brew link` resolves latest_kegs (cmd/link.rb), so a Cellar/<name> keg holding
    // two versions can't be pinned to the older one — the extract path installs it as
    // its own rack instead.
    let current = brewItem("wget", installed: ["1.2", "1.3"], linked: "1.3")
    let plan = versionSwitchPlan(for: current, to: "1.2", items: [current],
                                 taps: [installedTap("umputun/apps")])
    #expect(plan.isActionable == true)
    if case .extractInstall(let source, let version, _, _, let needsClone) = plan {
        // core absent from the tap list → treated as un-cloned (extract would
        // fail against the virtual tap), so the clone step is planned.
        #expect(source == "wget" && version == "1.2" && needsClone == true)
    } else {
        Issue.record("expected extractInstall, got \(plan)")
    }
}

// MARK: - Model command sequences

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

private let switchListJSON = """
{"formulae":[
 {"name":"wget","versions":["1.25"],"linked_version":"1.25","optlinked_version":"1.25","pinned_version":null}
],"casks":[]}
"""

private let virtualCoreTapsJSON = """
[{"name":"homebrew/core","installed":false},{"name":"umputun/apps","installed":true,"path":"/opt/homebrew/Library/Taps/umputun/homebrew-apps"}]
"""

private let clonedCoreTapsJSON = """
[{"name":"homebrew/core","installed":true,"path":"/opt/homebrew/Library/Taps/homebrew/homebrew-core"},{"name":"umputun/apps","installed":true}]
"""

@MainActor
private func makeSwitchHarness(listJSON: String, tapsJSON: String,
                               switchResults: [String: BrewResult],
                               probeRunning: Bool = false) -> (InventoryModel, ScriptedRunner) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var results: [String: BrewResult] = [
        "list --json --versions": ok(listJSON),
        "info --json=v2 --installed": ok("{\"formulae\":[],\"casks\":[]}"),
        "tap-info --installed --json": ok(tapsJSON),
        "trust --json=v1": ok("{}"),
    ]
    results.merge(switchResults) { _, new in new }
    let runner = ScriptedRunner(results: results)
    let model = InventoryModel(runner: runner,
                               manifestFetcher: ManifestFetcher(http: FakeHTTP(response: Data("{}".utf8)),
                                   cacheURL: dir.appendingPathComponent("manifest-cache.json")),
                               store: SnapshotStore(directory: dir),
                               brewProbe: FakeProbe(running: probeRunning),
                               jqAvailable: true, settings: InventorySettings())
    return (model, runner)
}

@MainActor
@Test func switch_extractInstallRunsTapCoreCloneExtractUnlinkInstall() async {
    let written = "==> Writing formula for wget at 1.21.1 from revision dead123 to:\n"
        + "/opt/homebrew/Library/Taps/umputun/homebrew-apps/Formula/wget@1.21.1.rb"
    let (model, runner) = makeSwitchHarness(listJSON: switchListJSON, tapsJSON: virtualCoreTapsJSON,
        switchResults: [
            "tap homebrew/core": ok(),
            "extract --force --version=1.21.1 wget umputun/apps": ok(written),
            "unlink --formula wget": ok(),
            "install -y umputun/apps/wget@1.21.1": ok(),
        ])
    await model.refresh(reason: .manual)
    await model.loadTaps()
    guard let item = model.items.first(where: { $0.name == "wget" }) else {
        Issue.record("fixture lost wget"); return
    }
    await model.switchFormulaVersion(item: item, version: "1.21.1", destinationTap: "umputun/apps")
    #expect(model.tapAction == .idle)
    let mutation = runner.calls.filter {
        $0.first == "tap" || $0.first == "extract" || $0.first == "unlink" || $0.first == "install"
    }
    #expect(mutation == [["tap", "homebrew/core"],
                         ["extract", "--force", "--version=1.21.1", "wget", "umputun/apps"],
                         ["unlink", "--formula", "wget"],
                         ["install", "-y", "umputun/apps/wget@1.21.1"]])
}

@MainActor
@Test func switch_clonedCoreSkipsTheTapStep() async {
    let (model, runner) = makeSwitchHarness(listJSON: switchListJSON, tapsJSON: clonedCoreTapsJSON,
        switchResults: [
            "extract --force --version=1.21.1 wget umputun/apps": ok("Formula/wget@1.21.1.rb"),
            "unlink --formula wget": ok(),
            "install -y umputun/apps/wget@1.21.1": ok(),
        ])
    await model.refresh(reason: .manual)
    await model.loadTaps()
    guard let item = model.items.first(where: { $0.name == "wget" }) else {
        Issue.record("fixture lost wget"); return
    }
    await model.switchFormulaVersion(item: item, version: "1.21.1", destinationTap: "umputun/apps")
    #expect(model.tapAction == .idle)
    #expect(runner.calls.first(where: { $0.first == "tap" }) == nil) // no clone when core is on disk
}

@MainActor
@Test func switch_relinkRouteUnlinksLinkedKeegsThenLinksTarget() async {
    let listJSON = """
    {"formulae":[
     {"name":"wget","versions":["1.25"],"linked_version":"1.25","optlinked_version":"1.25","pinned_version":null},
     {"name":"wget@1.21.1","versions":["1.21.1"],"linked_version":null,"optlinked_version":null,"pinned_version":null}
    ],"casks":[]}
    """
    let (model, runner) = makeSwitchHarness(listJSON: listJSON, tapsJSON: virtualCoreTapsJSON,
        switchResults: [
            "unlink --formula wget": ok(),
            "link --formula wget@1.21.1": ok(),
        ])
    await model.refresh(reason: .manual)
    guard let item = model.items.first(where: { $0.name == "wget" }) else {
        Issue.record("fixture lost wget"); return
    }
    await model.switchFormulaVersion(item: item, version: "1.21.1", destinationTap: "umputun/apps")
    #expect(model.tapAction == .idle)
    let mutation = runner.calls.filter { $0.first == "unlink" || $0.first == "link" }
    #expect(mutation == [["unlink", "--formula", "wget"], ["link", "--formula", "wget@1.21.1"]])
}

@MainActor
@Test func switch_extractFailureKeepsBrewsOwnWordingAndStillReloads() async {
    let (model, runner) = makeSwitchHarness(listJSON: switchListJSON, tapsJSON: clonedCoreTapsJSON,
        switchResults: [
            "extract --force --version=1.21.1 wget umputun/apps":
                fail("Error: Could not find wget! The formula or version may not have existed."),
        ])
    await model.refresh(reason: .manual)
    await model.loadTaps()
    guard let item = model.items.first(where: { $0.name == "wget" }) else {
        Issue.record("fixture lost wget"); return
    }
    await model.switchFormulaVersion(item: item, version: "1.21.1", destinationTap: "umputun/apps")
    #expect(model.tapAction == .failed(action: .switchingToVersion(qualified: "wget", version: "1.21.1"),
                                       message: "Error: Could not find wget! The formula or version may not have existed."))
    #expect(runner.calls.first(where: { $0.first == "install" }) == nil)
    // The failed extract attempt may still have changed tap state — the initial
    // refresh's list read plus the post-failure re-read both appear.
    #expect(runner.calls.filter { $0 == ["list", "--json", "--versions"] }.count >= 2)
}

@MainActor
@Test func switch_busyBrewRefusesBeforeRunningAnything() async {
    let (model, runner) = makeSwitchHarness(listJSON: switchListJSON, tapsJSON: clonedCoreTapsJSON,
        switchResults: [:], probeRunning: true)
    await model.refresh(reason: .manual)
    await model.loadTaps()
    guard let item = model.items.first(where: { $0.name == "wget" }) else {
        Issue.record("fixture lost wget"); return
    }
    await model.switchFormulaVersion(item: item, version: "1.21.1", destinationTap: "umputun/apps")
    if case .failed(_, let message) = model.tapAction {
        #expect(message.contains("brew is busy"))
    } else {
        Issue.record("expected busy failure, got \(model.tapAction)")
    }
    #expect(runner.calls.first(where: { $0.first == "extract" }) == nil)
}
