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
    // .formulae/.casks are no longer Section cases (kind moved to KindFilter);
    // allCases is the sidebar's row list, so it must not carry them.
    #expect(Section.allCases.count == 6)
    #expect(counts[.all] == 5)
    #expect(counts[.outdated] == 0) // everything upToDate or unknown, nothing counted
    #expect(counts[.pinned] == 0)
    #expect(counts[.deprecated] == 0)
    let greedyCounts = sidebarCounts(rows, greedy: true)
    #expect(greedyCounts[.outdated] == 1) // wireshark-app (auto_updates) surfaces as selfUpdating
}

@Test func sections_tapsIsNotAnInventoryFilter() throws {
    // Section.taps exists so the sidebar can use its proven tag/binding shape
    // for the taps pane (compat §7); it must never match inventory rows.
    let rows = try fixtureItems()
    #expect(items(rows, in: .taps, query: nil, greedy: false).isEmpty)
    #expect(sidebarCounts(rows, greedy: false)[.taps] == 0)
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
}

@Test func sections_kindFilterReplacesPerKindSections() throws {
    let rows = try fixtureItems()
    #expect(items(rows, kind: .all).count == 5)
    #expect(items(rows, kind: .formulae).count == 2)
    #expect(items(rows, kind: .casks).count == 3)
    // composes with search (the old section+filter composition, now kind+filter)
    #expect(items(items(rows, in: .all, query: "WIRE", greedy: false), kind: .casks)
        .map(\.name) == ["wireshark-app"])
    // kind filter feeds back into the same name/desc pipeline, both directions
    #expect(items(items(rows, kind: .casks), in: .all, query: "ral", greedy: false)
        .map(\.name) == ["revmux"])
}
