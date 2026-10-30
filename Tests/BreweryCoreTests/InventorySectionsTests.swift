import Foundation
import Testing
@testable import BreweryCore

// Items built from the real fixtures, with policy applied via manifest-mini.
private func fixtureItems() throws -> [BrewItem] {
    let list = try ListSnapshot.decode(fixtureData("list.json"))
    let info = try InfoSnapshot.decode(fixtureData("info.json"))
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-mini.json"))
    var items = InventoryMerger.merge(list: list, info: info)
    for i in items.indices {
        items[i].latestVersion = latestVersion(for: items[i], manifest: manifest)
        items[i].outdated = outdatedState(item: items[i], manifest: manifest, greedy: true) // stored states include .selfUpdating; sections hide it when greedy is off
    }
    return items // ace, agterm, ralphex, revmux, wireshark-app
}

@Test func sections_countsMatchDesignSnapshot() throws {
    let rows = try fixtureItems()
    let counts = sidebarCounts(rows, greedy: false)
    #expect(counts[.all] == 5)
    #expect(counts[.formulae] == 2)
    #expect(counts[.casks] == 3)
    #expect(counts[.outdated] == 0) // everything upToDate or unknown, nothing counted
    #expect(counts[.pinned] == 0)
    #expect(counts[.deprecated] == 0)
    let greedyCounts = sidebarCounts(rows, greedy: true)
    #expect(greedyCounts[.outdated] == 1) // wireshark-app (auto_updates) surfaces as selfUpdating
}

@Test func sections_outdatedSectionExcludesUnknown() throws {
    let rows = try fixtureItems()
    let ralphex = try #require(rows.first { $0.name == "ralphex" })
    #expect(ralphex.outdated == .unknown) // tap package absent from core manifest
    #expect(!items(rows, in: .outdated, query: nil, greedy: false).map(\.name).contains("ralphex"))
    #expect(!items(rows, in: .outdated, query: nil, greedy: true).map(\.name).contains("ralphex"))
}

@Test func sections_filterByNameSubstring() throws {
    let rows = try fixtureItems()
    let filtered = items(rows, in: .all, query: "ral", greedy: false)
    #expect(filtered.map(\.name) == ["ralphex", "revmux"]) // ralphex by name, revmux by desc "parallel" — substring over name + desc
    #expect(items(rows, in: .all, query: nil, greedy: false).count == 5)
    #expect(items(rows, in: .casks, query: "WIRE", greedy: false).map(\.name) == ["wireshark-app"]) // section + filter compose
}
