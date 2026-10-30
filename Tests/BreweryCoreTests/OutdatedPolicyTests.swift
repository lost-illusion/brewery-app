import Foundation
import Testing
@testable import BreweryCore

private func makeItem(_ kind: BrewItem.Kind, name: String, installed: [String],
                      autoUpdates: Bool = false, linked: String? = nil,
                      infoOutdated: Bool? = nil, infoVersion: String? = nil,
                      pinned: Bool = false) -> BrewItem {
    BrewItem(id: name, kind: kind, name: name, fullName: name, tap: "homebrew/core",
             installedVersions: installed, linkedVersion: linked, optlinkedVersion: nil,
             pinnedVersion: nil, latestVersion: nil, outdated: nil,
             infoOutdated: infoOutdated, infoVersion: infoVersion, isPinned: pinned,
             isDeprecated: false, deprecationReason: nil, isDisabled: false, disabledReason: nil,
             deprecationDate: nil, disableDate: nil, replacementFormula: nil, replacementCask: nil,
             desc: nil, homepage: nil, installedAt: nil, kegOnly: false,
             autoUpdates: autoUpdates, dependencies: [], sourceState: .complete)
}

private func manifest(_ json: String) throws -> PackageManifest {
    try PackageManifest.decode(jwsData: Data(json.utf8)) // decode accepts plain payload JSON
}

@Test func outdated_formulaUpdateAvailable() throws {
    let item = makeItem(.formula, name: "ace", installed: ["8.0.8"])
    let m = try manifest(#"{"formulae":{"ace":{"stable_version":"8.1.0"}},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .updateAvailable(latest: "8.1.0"))
}

@Test func outdated_formulaUpToDate() throws {
    let item = makeItem(.formula, name: "ace", installed: ["8.0.8"])
    let m = try manifest(#"{"formulae":{"ace":{"stable_version":"8.0.8"}},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
}

@Test func outdated_installedNewerThanKnownLatestIsNotUpdateAvailable() throws {
    // API regeneration lag or a tap shadowing a core name: installed is NEWER
    // than the manifest's known latest. Must not render an arrow to the older version.
    let item = makeItem(.formula, name: "ace", installed: ["8.1.2"])
    let m = try manifest(#"{"formulae":{"ace":{"stable_version":"8.0.8"}},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
    #expect(outdatedState(item: item, manifest: m, greedy: true) == .upToDate)
}

@Test func outdated_tapPackageUnknownNotUpToDate() throws {
    let item = makeItem(.formula, name: "ralphex", installed: ["1.0.1"]) // tap pkg: absent from core manifest
    let m = try manifest(#"{"formulae":{},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .unknown)
    #expect(latestVersion(for: item, manifest: m) == nil)
    #expect(outdatedState(item: item, manifest: nil, greedy: false) == .unknown) // no manifest fetched yet
}

@Test func outdated_autoUpdatesCaskNotCountedByDefault() throws {
    let item = makeItem(.cask, name: "wireshark-app", installed: ["4.6.9"], autoUpdates: true)
    let m = try manifest(#"{"formulae":{},"casks":{"wireshark-app":{"version":"4.7.0"}}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate) // brew-default
}

@Test func outdated_autoUpdatesCaskGreedyFlagsSelfUpdating() throws {
    let item = makeItem(.cask, name: "wireshark-app", installed: ["4.6.9"], autoUpdates: true)
    let m = try manifest(#"{"formulae":{},"casks":{"wireshark-app":{"version":"4.7.0"}}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: true) == .selfUpdating(latestKnown: "4.7.0"))
}

@Test func outdated_plainCaskUpdateAvailable() throws {
    let item = makeItem(.cask, name: "agterm", installed: ["0.38.1"])
    let m = try manifest(#"{"formulae":{},"casks":{"agterm":{"version":"0.39.0"}}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .updateAvailable(latest: "0.39.0"))
}

@Test func outdated_installedLatestMarker() throws {
    let item = makeItem(.cask, name: "librewolf", installed: [":latest"])
    let m = try manifest(#"{"formulae":{},"casks":{"librewolf":{"version":"1.2"}}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
    #expect(outdatedState(item: item, manifest: m, greedy: true) == .selfUpdating(latestKnown: "1.2"))
}

// Tap packages live outside the core manifest; brew's installed-info carries
// its own verdict (outdated boolean) and its own latest version (agterm live
// 2026-10-30: version 0.39.1 while installed 0.38.1). awscli/core formulae
// prove `versions.stable` means latest-known, not installed (2.39.2 vs 2.39.1).

@Test func outdated_tapCaskUsesBrewOutdatedBoolean() throws {
    let item = makeItem(.cask, name: "agterm", installed: ["0.38.1"],
                        infoOutdated: true, infoVersion: "0.39.1")
    let m = try manifest(#"{"formulae":{},"casks":{}}"#) // agterm absent: tap cask
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .updateAvailable(latest: "0.39.1"))
    #expect(latestVersion(for: item, manifest: m) == "0.39.1")
    #expect(outdatedState(item: item, manifest: nil, greedy: false) == .updateAvailable(latest: "0.39.1"))
}

@Test func outdated_tapFormulaBrewSaysCurrentIsUpToDate() throws {
    // brew's boolean is the authority on a manifest miss: it compares against
    // the tap definition the GUI cannot read, so its "no" wins even when the
    // reported version string differs from the installed one.
    let item = makeItem(.formula, name: "cronn", installed: ["1.0.1"],
                        infoOutdated: false, infoVersion: "1.0.2")
    let m = try manifest(#"{"formulae":{},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
}

@Test func outdated_tapInstalledNewerThanInfoVersionNeverArrowsBack() throws {
    let item = makeItem(.formula, name: "cronn", installed: ["2.0.0"],
                        infoOutdated: false, infoVersion: "1.0.2")
    #expect(outdatedState(item: item, manifest: nil, greedy: false) == .upToDate)
}

@Test func outdated_tapCaskSelfUpdatingStillFollowsGreedy() throws {
    let item = makeItem(.cask, name: "supertool", installed: ["1.0"], autoUpdates: true,
                        infoOutdated: true, infoVersion: "2.0")
    #expect(outdatedState(item: item, manifest: nil, greedy: false) == .upToDate)
    #expect(outdatedState(item: item, manifest: nil, greedy: true) == .selfUpdating(latestKnown: "2.0"))
}

@Test func outdated_coreManifestWinsOverInfoFields() throws {
    // A manifest hit keeps the existing compare semantics; the info fallback is
    // only for manifest misses.
    let item = makeItem(.formula, name: "ace", installed: ["8.0.8"],
                        infoOutdated: true, infoVersion: "8.1.0")
    let m = try manifest(#"{"formulae":{"ace":{"stable_version":"8.0.8"}},"casks":{}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
}

@Test func outdated_listOnlyRowStaysUnknown() throws {
    // No info JSON (untrusted tap, §43): both info fields nil → old .unknown.
    let item = makeItem(.cask, name: "ghost", installed: ["1.0"])
    #expect(outdatedState(item: item, manifest: nil, greedy: false) == .unknown)
    #expect(latestVersion(for: item, manifest: nil) == nil)
}

@Test func outdated_manifestLatestMarker() throws {
    let item = makeItem(.cask, name: "docker", installed: ["4.6.9"])
    let m = try manifest(#"{"formulae":{},"casks":{"docker":{"version":":latest"}}}"#)
    #expect(outdatedState(item: item, manifest: m, greedy: false) == .upToDate)
    // ":latest" upstream: newest known is what the user already has
    #expect(outdatedState(item: item, manifest: m, greedy: true) == .selfUpdating(latestKnown: "4.6.9"))
}
