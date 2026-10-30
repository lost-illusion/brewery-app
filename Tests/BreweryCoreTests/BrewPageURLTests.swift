import Foundation
import Testing
@testable import BreweryCore

private func item(_ kind: BrewItem.Kind, name: String, tap: String?) -> BrewItem {
    BrewItem(id: name, kind: kind, name: name, fullName: name, tap: tap,
             installedVersions: ["1.0"], linkedVersion: nil, optlinkedVersion: nil,
             pinnedVersion: nil, latestVersion: nil, outdated: nil, isPinned: false,
             isDeprecated: false, deprecationReason: nil, isDisabled: false, disabledReason: nil,
             desc: nil, homepage: nil, installedAt: nil, kegOnly: false,
             autoUpdates: false, dependencies: [], sourceState: .complete)
}

@Test func brewPage_corePackagesUseSitePages() {
    let f = brewPageURL(for: item(.formula, name: "ace", tap: "homebrew/core"))
    #expect(f?.absoluteString == "https://formulae.brew.sh/formula/ace")
    let c = brewPageURL(for: item(.cask, name: "wireshark-app", tap: "homebrew/core"))
    #expect(c?.absoluteString == "https://formulae.brew.sh/cask/wireshark-app")
}

@Test func brewPage_thirdPartyTapFallsBackToTapRepo() {
    // Third-party tap packages are absent from formulae.brew.sh (compatibilities §23);
    // the tap's GitHub repo (owner/homebrew-<repo>) is the brew page.
    let u = brewPageURL(for: item(.formula, name: "ralphex", tap: "umputun/apps"))
    #expect(u?.absoluteString == "https://github.com/umputun/homebrew-apps")
    // A tap whose repo already carries the prefix is used as-is.
    let v = brewPageURL(for: item(.cask, name: "foo", tap: "homebrew/homebrew-cask-versions"))
    #expect(v?.absoluteString == "https://github.com/Homebrew/homebrew-cask-versions")
}

@Test func brewPage_unknownTapIsNil() {
    let u = brewPageURL(for: item(.formula, name: "x", tap: nil)) // text-list rows have no tap
    #expect(u == nil)
}
