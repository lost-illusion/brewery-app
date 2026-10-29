import Foundation

public struct ListSnapshot: Codable {
    public struct FormulaItem: Codable {
        public let name: String
        public let versions: [String]
        public let linkedVersion: String?
        public let optlinkedVersion: String?
        public let pinnedVersion: String?

        enum CodingKeys: String, CodingKey {
            case name, versions
            case linkedVersion = "linked_version"
            case optlinkedVersion = "optlinked_version"
            case pinnedVersion = "pinned_version"
        }
    }

    public struct CaskItem: Codable {
        public let token: String // token, NOT name — verified §47
        public let versions: [String]
        public let pinnedVersion: String?

        enum CodingKeys: String, CodingKey {
            case token, versions
            case pinnedVersion = "pinned_version"
        }
    }

    public let formulae: [FormulaItem]
    public let casks: [CaskItem]

    public static func decode(_ data: Data) throws -> ListSnapshot {
        try JSONDecoder().decode(ListSnapshot.self, from: data)
    }
}
