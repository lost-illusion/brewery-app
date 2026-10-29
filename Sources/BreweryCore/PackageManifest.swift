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

    /// The JWS uses b64:false: the payload is raw JSON between the first and
    /// last dot. Strip the signature; decode the payload. Plain JSON (no dots)
    /// is accepted so cached envelopes can be re-read without the wrapper.
    public static func decode(jwsData: Data) throws -> PackageManifest {
        guard let text = String(data: jwsData, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "manifest is not UTF-8"))
        }
        let payload: String
        if let first = text.firstIndex(of: "."), let last = text.lastIndex(of: "."), first < last {
            payload = String(text[text.index(after: first)..<last])
        } else {
            payload = text
        }
        return try JSONDecoder().decode(PackageManifest.self, from: Data(payload.utf8))
    }
}
