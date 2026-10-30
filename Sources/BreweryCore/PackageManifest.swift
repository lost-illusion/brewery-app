import Foundation

/// Decoded payload of https://formulae.brew.sh/api/internal/packages.<bottle_tag>.jws.json
/// (core-only: no tap packages, no installed state — see compatibilities §23).
public struct PackageManifest: Decodable {
    public struct FormulaEntry: Decodable {
        public let stableVersion: String?
        public let desc: String?
        public let homepage: String?
        public let license: String?

        enum CodingKeys: String, CodingKey {
            case desc, homepage, license
            case stableVersion = "stable_version"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stableVersion = try c.decodeIfPresent(String.self, forKey: .stableVersion)
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            // license is a String in most formulae but an SPDX expression object
            // (":all_of"/":any_of"/":with" nesting) in ~10% of the live payload.
            if let s = try? c.decodeIfPresent(String.self, forKey: .license) {
                license = s
            } else if let spdx = try? c.decodeIfPresent(SPDXValue.self, forKey: .license) {
                let ids = Set(spdx.licenseIDs).filter { !$0.hasPrefix(":") }
                license = ids.isEmpty ? nil : ids.sorted().joined(separator: ", ")
            } else {
                license = nil
            }
        }
    }

    /// Recursive decode of Homebrew's SPDX license expression objects.
    private enum SPDXValue: Decodable {
        case string(String)
        case array([SPDXValue])
        case object([String: SPDXValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([SPDXValue].self) { self = .array(a); return }
            self = .object(try c.decode([String: SPDXValue].self))
        }

        var licenseIDs: [String] {
            switch self {
            case .string(let s): [s]
            case .array(let a): a.flatMap(\.licenseIDs)
            case .object(let o): o.flatMap { key, value in
                key.hasPrefix(":") ? value.licenseIDs : [key] + value.licenseIDs
            }
            }
        }
    }

    public struct CaskEntry: Decodable {
        public let version: String?
        public let tapString: String?
        public let name: String?

        enum CodingKeys: String, CodingKey {
            case version, name
            case tapString = "tap_string"
        }
    }

    private struct Metadata: Decodable {
        let bottleTag: String?
        enum CodingKeys: String, CodingKey { case bottleTag = "bottle_tag" }
    }

    public let formulae: [String: FormulaEntry]
    public let casks: [String: CaskEntry]
    public let bottleTag: String?

    private enum CodingKeys: String, CodingKey {
        case formulae, casks, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try c.decodeIfPresent([String: FormulaEntry].self, forKey: .formulae) ?? [:]
        casks = try c.decodeIfPresent([String: CaskEntry].self, forKey: .casks) ?? [:]
        bottleTag = try c.decodeIfPresent(Metadata.self, forKey: .metadata)?.bottleTag
    }

    public func latestFormulaVersion(_ name: String) -> String? {
        formulae[name]?.stableVersion
    }

    public func latestCaskVersion(_ token: String) -> String? {
        casks[token]?.version
    }

    /// Accepts all three shapes the endpoint/cache can hold (compatibilities §23):
    /// - JWS JSON serialization (the live format): {"payload":"<manifest JSON>","signatures":[…]}
    /// - compact JWS (b64:false): payload is raw JSON between the first and last dot
    /// - plain manifest JSON: the cached envelope re-read without a wrapper
    public static func decode(jwsData: Data) throws -> PackageManifest {
        guard let text = String(data: jwsData, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "manifest is not UTF-8"))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if trimmed.hasPrefix("{") {
            // JWS JSON serialization: the manifest hides inside the "payload" string.
            // Plain manifest JSON decodes with payload == nil and is used verbatim —
            // its dots are inside strings and must NOT be split on.
            struct JWSJSON: Decodable { let payload: String? }
            if let wrapper = try? JSONDecoder().decode(JWSJSON.self, from: Data(trimmed.utf8)),
               let inner = wrapper.payload {
                payload = inner
            } else {
                payload = trimmed
            }
        } else if let first = trimmed.firstIndex(of: "."), let last = trimmed.lastIndex(of: "."), first < last {
            // Compact JWS starts with the base64url header ("eyJ…"); the dots around
            // the payload are the first/last dots in the text.
            payload = String(trimmed[trimmed.index(after: first)..<last])
        } else {
            payload = trimmed
        }
        return try JSONDecoder().decode(PackageManifest.self, from: Data(payload.utf8))
    }
}
