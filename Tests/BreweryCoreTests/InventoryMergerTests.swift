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
