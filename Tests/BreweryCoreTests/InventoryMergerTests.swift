import Foundation
import Testing
@testable import BreweryCore

private func json(_ s: String) -> Data { Data(s.utf8) }

private func realSnapshots() throws -> (ListSnapshot, InfoSnapshot) {
    (try ListSnapshot.decode(fixtureData("list.json")),
     try InfoSnapshot.decode(fixtureData("info.json")))
}

@Test func merger_formulaMergesInfoOntoListRow() throws {
    let (list, info) = try realSnapshots()
    let items = InventoryMerger.merge(list: list, info: info)
    let ace = try #require(items.first { $0.name == "ace" })
    #expect(ace.kind == .formula)
    #expect(ace.desc != nil) // info-side field lands on the list row
    #expect(ace.tap == "homebrew/core")
    #expect(ace.sourceState == .complete)
    #expect(ace.installedAt != nil) // installed[0].time
    #expect(ace.installedVersions == ["8.0.8"])
}

@Test func merger_casksMergeOnToken() throws {
    let (list, info) = try realSnapshots()
    let items = InventoryMerger.merge(list: list, info: info)
    let listVersions = Dictionary(list.casks.map { ($0.token, $0.versions) }, uniquingKeysWith: { a, _ in a })
    for token in ["agterm", "revmux", "wireshark-app"] { // matched on token, not name — §47
        let cask = try #require(items.first { $0.name == token && $0.kind == .cask })
        #expect(cask.sourceState == .complete)
        #expect(cask.installedVersions == listVersions[token])
    }
    let wireshark = try #require(items.first { $0.name == "wireshark-app" })
    #expect(wireshark.autoUpdates == true) // info-side cask field
}

@Test func merger_untrustedRowStaysAsListOnly() throws {
    let (list, info) = try realSnapshots()
    let items = InventoryMerger.merge(list: list, info: info)
    let ralphex = try #require(items.first { $0.name == "ralphex" }) // in list, omitted by info — §43
    #expect(ralphex.sourceState == .listOnly(reason: "no source info — untrusted tap or API skew"))
    #expect(ralphex.latestVersion == nil)
    #expect(ralphex.infoOutdated == nil) // no info JSON → no brew verdict, stays .unknown
    #expect(ralphex.infoVersion == nil)
    #expect(ralphex.desc == nil)
    #expect(ralphex.installedVersions == ["1.0.1"]) // versions survive from list
}

@Test func merger_reverseSkewInfoOnlyRow() throws {
    let list = try ListSnapshot.decode(json(#"{"formulae":[],"casks":[]}"#))
    let info = try InfoSnapshot.decode(json(#"""
    {"formulae":[{"name":"ghostpkg","full_name":"homebrew/core/ghostpkg","tap":"homebrew/core",
      "installed":[{"version":"1.0","time":1730000000}],"linked_keg":"1.0","pinned":false,
      "outdated":true,"deprecated":false,"disabled":false,"keg_only":false,
      "desc":"ghost","homepage":"https://example.com","dependencies":[]}],"casks":[]}
    """#))
    let items = InventoryMerger.merge(list: list, info: info)
    let ghost = try #require(items.first { $0.name == "ghostpkg" })
    #expect(ghost.sourceState == .infoOnly)
    #expect(ghost.installedVersions == ["1.0"]) // versions fall back to info.installed
    #expect(ghost.infoOutdated == true)         // brew's own verdict rides along (§22)
    #expect(ghost.infoVersion == nil)           // fixture has no versions.stable
}

@Test func merger_tapCaskCarriesBrewOutdatedAndVersion() throws {
    // Live JSON shape 2026-10-30: agterm installed 0.38.1, tap definition at
    // 0.39.1 — info.outdated true, cask `version` 0.39.1. The merger must hand
    // both to the policy so the main inventory arrows to 0.39.1.
    let list = try ListSnapshot.decode(json(#"{"formulae":[],"casks":[{"token":"agterm","versions":["0.38.1"]}]}"#))
    let info = try InfoSnapshot.decode(json(#"""
    {"formulae":[],"casks":[{"token":"agterm","installed":"0.38.1","installed_time":1761749040,
      "outdated":true,"pinned":false,"deprecated":false,"disabled":false,"auto_updates":false,
      "version":"0.39.1","tap":"umputun/apps","homepage":"https://github.com/umputun/agterm",
      "depends_on":{"formula":["gnupg"]}}]}
    """#))
    let item = try #require(InventoryMerger.merge(list: list, info: info).first { $0.name == "agterm" })
    #expect(item.infoOutdated == true)
    #expect(item.infoVersion == "0.39.1")
    #expect(item.latestVersion == nil) // merger leaves it; applyPolicy computes it
    let state = outdatedState(item: item, manifest: nil, greedy: false) // no manifest entry: tap cask
    #expect(state == .updateAvailable(latest: "0.39.1"))
    #expect(latestVersion(for: item, manifest: nil) == "0.39.1") // "Latest known" fact line
}

@Test func merger_caskDisabledPropagates() throws {
    // Casks carry the same disable_* fields as formulae; the merger must not
    // hardcode them away (old behavior: isDisabled always false for casks).
    let list = try ListSnapshot.decode(json(#"{"formulae":[],"casks":[{"token":"old-app","versions":["1.0"]}]}"#))
    let info = try InfoSnapshot.decode(json(#"""
    {"formulae":[],"casks":[{"token":"old-app","installed":"1.0","deprecated":true,
      "deprecation_reason":"discontinued","deprecation_date":"2026-01-01",
      "deprecation_replacement_cask":"transitional-app",
      "disabled":true,"disable_date":"2026-09-01","disable_reason":"discontinued",
      "disable_replacement_cask":"new-app"}]}
    """#))
    let items = InventoryMerger.merge(list: list, info: info)
    let cask = try #require(items.first { $0.name == "old-app" })
    #expect(cask.isDisabled == true)
    #expect(cask.disabledReason == "discontinued")
    #expect(cask.disableDate == "2026-09-01")
    // Homebrew precedence: the disable pair wins while disabled — the deprecation
    // replacement is intentionally dropped (DeprecateDisable.message).
    #expect(cask.replacementCask == "new-app")
    #expect(cask.replacementFormula == nil)
    let notice = try #require(DeprecationNotice(cask))
    #expect(notice.status == .disabled)
    #expect(notice.text == "This cask has been disabled since 2026-09-01 because it is discontinued upstream.")
    #expect(notice.replacementCommand == "brew install --cask new-app")
}

@Test func merger_sortedByName() throws {
    let list = try ListSnapshot.decode(json(#"""
    {"formulae":[{"name":"Zeta","versions":["1.0"]},{"name":"alpha","versions":["2.0"]},
      {"name":"Beta","versions":["3.0"]}],"casks":[]}
    """#))
    let info = try InfoSnapshot.decode(json(#"{"formulae":[],"casks":[]}"#))
    let items = InventoryMerger.merge(list: list, info: info)
    #expect(items.map(\.name) == ["alpha", "Beta", "Zeta"]) // case-insensitive
}
