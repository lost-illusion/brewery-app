import Foundation

public struct BrewItem: Identifiable, Hashable, Codable {
    public enum Kind: String, Hashable, Codable {
        case formula, cask
    }

    public enum SourceState: Hashable, Codable {
        case complete
        case listOnly(reason: String)
        case infoOnly
    }

    public let id: String // fullName (formula) or token (cask)
    public let kind: Kind
    public let name: String // formula name / cask token
    public let fullName: String
    public let tap: String?
    public let installedVersions: [String]
    public let linkedVersion: String?
    public let optlinkedVersion: String?
    public let pinnedVersion: String?
    public var latestVersion: String? // filled by Task 8 logic
    public var outdated: OutdatedState? // filled by Task 8 logic
    public let isPinned: Bool
    public let isDeprecated: Bool
    public let deprecationReason: String?
    public let isDisabled: Bool
    public let disabledReason: String?
    public let deprecationDate: String? // ISO "2026-10-15", verbatim from info JSON
    public let disableDate: String?
    public let replacementFormula: String? // merger resolves: disable pair when disabled, else deprecation pair
    public let replacementCask: String?
    public let desc: String?
    public let homepage: String?
    public let installedAt: Date?
    public let kegOnly: Bool
    public let autoUpdates: Bool // false for formulae
    public let dependencies: [String]
    public let sourceState: SourceState
}
