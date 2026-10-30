import Foundation
import Testing
@testable import BreweryCore

private func item(_ kind: BrewItem.Kind = .formula,
                  deprecated: Bool = false, deprecationReason: String? = nil, deprecationDate: String? = nil,
                  disabled: Bool = false, disabledReason: String? = nil, disableDate: String? = nil,
                  repFormula: String? = nil, repCask: String? = nil) -> BrewItem {
    BrewItem(id: "x", kind: kind, name: "x", fullName: "homebrew/core/x", tap: "homebrew/core",
             installedVersions: ["1.0"], linkedVersion: nil, optlinkedVersion: nil, pinnedVersion: nil,
             latestVersion: nil, outdated: nil, infoOutdated: nil, infoVersion: nil, isPinned: false,
             isDeprecated: deprecated, deprecationReason: deprecationReason,
             isDisabled: disabled, disabledReason: disabledReason,
             deprecationDate: deprecationDate, disableDate: disableDate,
             replacementFormula: repFormula, replacementCask: repCask,
             desc: nil, homepage: nil, installedAt: nil, kegOnly: false,
             autoUpdates: false, dependencies: [], sourceState: .complete)
}

@Test func notice_nilForPlainPackage() {
    #expect(DeprecationNotice(item()) == nil)
}

@Test func notice_disabledFormulaMatchesSiteHeading() throws {
    // python@3.9 on formulae.brew.sh: "This formula has been disabled since
    // 2026-10-15 because it is deprecated upstream" — disabled wins though both flags are set.
    let n = try #require(DeprecationNotice(item(
        deprecated: true, deprecationReason: "deprecated_upstream", deprecationDate: "2025-10-15",
        disabled: true, disabledReason: "deprecated_upstream", disableDate: "2026-10-15")))
    #expect(n.status == .disabled)
    #expect(n.text == "This formula has been disabled since 2026-10-15 because it is deprecated upstream.")
}

@Test func notice_deprecatedFormulaSiteWording() throws {
    // python@3.10: "This formula has been deprecated since 2026-10-01 because it is deprecated upstream"
    let n = try #require(DeprecationNotice(item(
        deprecated: true, deprecationReason: "deprecated_upstream", deprecationDate: "2026-10-01")))
    #expect(n.status == .deprecated)
    #expect(n.text == "This formula has been deprecated since 2026-10-01 because it is deprecated upstream.")
}

@Test func notice_omitsUnknownClauses() throws {
    let n = try #require(DeprecationNotice(item(disabled: true)))
    #expect(n.text == "This formula has been disabled.")
}

@Test func notice_unknownReasonPassesThroughVerbatim() throws {
    // deprecate! accepts a free-form string reason; only known symbols are mapped.
    let n = try #require(DeprecationNotice(item(
        deprecated: true, deprecationReason: "superseded by the upstream project")))
    #expect(n.text == "This formula has been deprecated because it superseded by the upstream project.")
}

@Test func notice_caskReasonMapping() throws {
    let n = try #require(DeprecationNotice(item(.cask, disabled: true, disabledReason: "moved_to_mas")))
    #expect(n.text == "This cask has been disabled because it is now exclusively distributed on the Mac App Store.")
}

@Test func notice_formulaReasonMapDoesNotLeakIntoCasks() throws {
    // "unsupported" is a formula reason; a cask with it falls through raw.
    let n = try #require(DeprecationNotice(item(.cask, deprecated: true, deprecationReason: "unsupported")))
    #expect(n.text == "This cask has been deprecated because it unsupported.")
}

@Test func notice_replacementCommandFollowsHomebrewWording() {
    #expect(DeprecationNotice(item(disabled: true, repFormula: "python@3.14"))?
        .replacementCommand == "brew install --formula python@3.14")
    #expect(DeprecationNotice(item(.cask, disabled: true, repCask: "foo-app"))?
        .replacementCommand == "brew install --cask foo-app")
    // Identical formula/cask names print without a flag (replacement_with_type).
    #expect(DeprecationNotice(item(disabled: true, repFormula: "bar", repCask: "bar"))?
        .replacementCommand == "brew install bar")
    #expect(DeprecationNotice(item(disabled: true))?.replacementCommand == nil)
}
