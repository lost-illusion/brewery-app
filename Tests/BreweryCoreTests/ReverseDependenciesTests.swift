import Foundation
import Testing
@testable import BreweryCore

private func item(_ id: String, _ name: String, deps: [String] = [],
                  kind: BrewItem.Kind = .formula, tap: String? = "homebrew/core") -> BrewItem {
    BrewItem(id: id, kind: kind, name: name, fullName: id, tap: tap,
             installedVersions: ["1.0"], linkedVersion: "1.0", optlinkedVersion: nil, pinnedVersion: nil,
             latestVersion: nil, outdated: nil, infoOutdated: nil, infoVersion: nil, isPinned: false, isDeprecated: false, deprecationReason: nil,
             isDisabled: false, disabledReason: nil, deprecationDate: nil, disableDate: nil,
             replacementFormula: nil, replacementCask: nil, desc: nil, homepage: nil, installedAt: nil,
             kegOnly: false, autoUpdates: false, dependencies: deps, sourceState: .complete)
}

@Test func reverseDeps_directDependentsInInventoryOrder() {
    let items = [item("openssl@3", "openssl@3"),
                 item("curl", "curl", deps: ["openssl@3"]),
                 item("wget", "wget", deps: ["openssl@3", "libidn2"])]
    let rev = ReverseDependencies(items: items)
    #expect(rev.dependents(of: items[0]).map(\.id) == ["curl", "wget"])
}

@Test func reverseDeps_caskDependsOnFormulaAndCask() {
    let items = [item("wireshark", "wireshark"),
                 item("wireshark-app", "wireshark-app", deps: ["wireshark"], kind: .cask)]
    let rev = ReverseDependencies(items: items)
    #expect(rev.dependents(of: items[0]).map(\.id) == ["wireshark-app"])
    #expect(rev.dependents(of: items[1]).isEmpty) // formula is not a dependent of the cask
}

@Test func reverseDeps_fullNameDepResolvesToId() {
    let thirdParty = item("alice/tap/tool", "tool", deps: ["homebrew/core/openssl@3"])
    let rev = ReverseDependencies(items: [item("homebrew/core/openssl@3", "openssl@3"), thirdParty])
    #expect(rev.dependents(of: item("homebrew/core/openssl@3", "openssl@3")).map(\.id) == ["alice/tap/tool"])
}

@Test func reverseDeps_noDepTargetInInventoryIsIgnored() {
    // Dependency installed nowhere in this inventory — nothing to report.
    let rev = ReverseDependencies(items: [item("wget", "wget", deps: ["not-installed-lib"])])
    #expect(rev.dependents(of: item("wget", "wget")).isEmpty)
}

@Test func reverseDeps_noSelfDependents() {
    let rev = ReverseDependencies(items: [item("odd", "odd", deps: ["odd"])])
    #expect(rev.dependents(of: item("odd", "odd")).isEmpty)
}

@Test func reverseDeps_nameCollisionsFollowChipResolution() {
    // A bare dep string resolves to an item whose id matches first (cask token
    // "foo"), same as the detail-page chip index.
    let formula = item("homebrew/core/foo", "foo")
    let cask = item("foo", "foo", kind: .cask, tap: "homebrew/cask")
    let dependent = item("user", "user", deps: ["foo"])
    let rev = ReverseDependencies(items: [formula, cask, dependent])
    #expect(rev.dependents(of: cask).map(\.id) == ["user"])
    #expect(rev.dependents(of: formula).isEmpty)
}
