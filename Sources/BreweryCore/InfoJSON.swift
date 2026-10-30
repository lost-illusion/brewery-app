import Foundation

public struct InfoSnapshot: Decodable {
    public struct InstalledRecord: Codable {
        public let version: String
        public let time: Date? // JSON time = epoch seconds
    }

    public struct FormulaInfo: Decodable {
        public let name: String
        public let fullName: String
        public let tap: String
        public let installed: [InstalledRecord]
        public let linkedKeg: String?
        public let pinned: Bool
        public let outdated: Bool
        public let deprecated: Bool
        public let deprecationReason: String?
        public let disabled: Bool
        public let disabledReason: String?
        public let deprecationDate: String?
        public let disableDate: String?
        public let deprecationReplacementFormula: String?
        public let deprecationReplacementCask: String?
        public let disableReplacementFormula: String?
        public let disableReplacementCask: String?
        public let kegOnly: Bool
        public let desc: String?
        public let homepage: String?
        public let dependencies: [String]
        public let versionsStable: String?
        public let bottleTag: String? // first key of bottle.stable.files, e.g. "arm64_golden_gate"

        private struct VersionsDTO: Codable { let stable: String? }
        private struct BottleDTO: Codable {
            struct StableDTO: Codable {
                struct FileDTO: Codable { let cellar: String?; let url: String?; let sha256: String? }
                let files: [String: FileDTO]?
            }
            let stable: StableDTO?
        }

        enum CodingKeys: String, CodingKey {
            case name, tap, installed, desc, homepage, dependencies
            case fullName = "full_name"
            case linkedKeg = "linked_keg"
            case pinned, outdated, deprecated
            case deprecationReason = "deprecation_reason"
            case disabled
            case disabledReason = "disable_reason"
            case deprecationDate = "deprecation_date"
            case disableDate = "disable_date"
            case deprecationReplacementFormula = "deprecation_replacement_formula"
            case deprecationReplacementCask = "deprecation_replacement_cask"
            case disableReplacementFormula = "disable_replacement_formula"
            case disableReplacementCask = "disable_replacement_cask"
            case kegOnly = "keg_only"
            case versions, bottle
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? name
            tap = try c.decodeIfPresent(String.self, forKey: .tap) ?? ""
            installed = try c.decodeIfPresent([InstalledRecord].self, forKey: .installed) ?? []
            linkedKeg = try c.decodeIfPresent(String.self, forKey: .linkedKeg)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            outdated = try c.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
            deprecated = try c.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
            deprecationReason = try c.decodeIfPresent(String.self, forKey: .deprecationReason)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
            deprecationDate = try c.decodeIfPresent(String.self, forKey: .deprecationDate)
            disableDate = try c.decodeIfPresent(String.self, forKey: .disableDate)
            deprecationReplacementFormula = try c.decodeIfPresent(String.self, forKey: .deprecationReplacementFormula)
            deprecationReplacementCask = try c.decodeIfPresent(String.self, forKey: .deprecationReplacementCask)
            disableReplacementFormula = try c.decodeIfPresent(String.self, forKey: .disableReplacementFormula)
            disableReplacementCask = try c.decodeIfPresent(String.self, forKey: .disableReplacementCask)
            kegOnly = try c.decodeIfPresent(Bool.self, forKey: .kegOnly) ?? false
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
            versionsStable = try c.decodeIfPresent(VersionsDTO.self, forKey: .versions)?.stable
            bottleTag = try c.decodeIfPresent(BottleDTO.self, forKey: .bottle)?.stable?.files?.keys.min()
        }
    }

    public struct CaskInfo: Decodable {
        public let token: String
        public let installedVersion: String? // cask `installed` is a STRING, not array — §45
        public let installedTime: Date?
        public let outdated: Bool
        public let pinned: Bool
        public let deprecated: Bool
        public let deprecationReason: String?
        public let disabled: Bool
        public let disabledReason: String?
        public let deprecationDate: String?
        public let disableDate: String?
        public let deprecationReplacementFormula: String?
        public let deprecationReplacementCask: String?
        public let disableReplacementFormula: String?
        public let disableReplacementCask: String?
        public let autoUpdates: Bool
        public let versionLatest: String? // `version` field
        public let desc: String?
        public let homepage: String?
        public let tap: String

        enum CodingKeys: String, CodingKey {
            case token, installed, outdated, pinned, deprecated, desc, homepage, tap
            case installedTime = "installed_time"
            case deprecationReason = "deprecation_reason"
            case disabled
            case disabledReason = "disable_reason"
            case deprecationDate = "deprecation_date"
            case disableDate = "disable_date"
            case deprecationReplacementFormula = "deprecation_replacement_formula"
            case deprecationReplacementCask = "deprecation_replacement_cask"
            case disableReplacementFormula = "disable_replacement_formula"
            case disableReplacementCask = "disable_replacement_cask"
            case autoUpdates = "auto_updates"
            case versionLatest = "version"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            installedVersion = try c.decodeIfPresent(String.self, forKey: .installed)
            installedTime = try c.decodeIfPresent(Double.self, forKey: .installedTime)
                .map { Date(timeIntervalSince1970: $0) }
            outdated = try c.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            deprecated = try c.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
            deprecationReason = try c.decodeIfPresent(String.self, forKey: .deprecationReason)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
            deprecationDate = try c.decodeIfPresent(String.self, forKey: .deprecationDate)
            disableDate = try c.decodeIfPresent(String.self, forKey: .disableDate)
            deprecationReplacementFormula = try c.decodeIfPresent(String.self, forKey: .deprecationReplacementFormula)
            deprecationReplacementCask = try c.decodeIfPresent(String.self, forKey: .deprecationReplacementCask)
            disableReplacementFormula = try c.decodeIfPresent(String.self, forKey: .disableReplacementFormula)
            disableReplacementCask = try c.decodeIfPresent(String.self, forKey: .disableReplacementCask)
            autoUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoUpdates) ?? false
            versionLatest = try c.decodeIfPresent(String.self, forKey: .versionLatest)
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            tap = try c.decodeIfPresent(String.self, forKey: .tap) ?? ""
        }
    }

    public let formulae: [FormulaInfo]
    public let casks: [CaskInfo]

    public static func decode(_ data: Data) throws -> InfoSnapshot {
        try JSONDecoder().decode(InfoSnapshot.self, from: data)
    }
}
