import Foundation
import Testing
@testable import BreweryCore

@Test func brewItem_minimal_roundTrip() throws {
    let item = BrewItem(
        id: "ace", kind: .formula, name: "ace", fullName: "ace", tap: "homebrew/core",
        installedVersions: ["8.0.8"], linkedVersion: nil, optlinkedVersion: nil, pinnedVersion: nil,
        latestVersion: nil, outdated: nil, isPinned: false, isDeprecated: false, deprecationReason: nil,
        isDisabled: false, disabledReason: nil, deprecationDate: nil, disableDate: nil,
        replacementFormula: nil, replacementCask: nil, desc: nil, homepage: nil, installedAt: nil,
        kegOnly: false, autoUpdates: false, dependencies: [], sourceState: .complete
    )
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(BrewItem.self, from: data)
    #expect(decoded == item)
}
