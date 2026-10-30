import Foundation

/// Item-level trust grants read from `brew trust --json=v1` (compat §22).
/// Entries are fully qualified (`umputun/apps/revdiff`); a per-item grant does
/// NOT make its tap trusted — `tap-info` still reports `trusted:false` while
/// brew loads these individual definitions (§22, observed on this machine).
/// Unlike `list`/`info` JSON, this command emits JSON without jq (verified
/// 2026-10-30 with jq off PATH), so reading it is safe under the no-jq posture.
/// The decoder also accepts brew's on-disk store shape (`~/.homebrew/trust.json`:
/// `trustedformulae`/`trustedcasks` keys) — same values, different key spelling.
public struct TrustStore: Decodable, Equatable {
    public let taps: Set<String>
    public let formulae: Set<String>
    public let casks: Set<String>
    public let commands: Set<String>

    public init(taps: Set<String> = [], formulae: Set<String> = [],
                casks: Set<String> = [], commands: Set<String> = []) {
        self.taps = taps; self.formulae = formulae; self.casks = casks; self.commands = commands
    }

    /// Qualified (`tap/name`) → granted for this kind. Tap-level trust is checked
    /// separately via `TapInfo.trusted`; it grants everything under the tap.
    public func isTrusted(qualified: String, kind: BrewItem.Kind) -> Bool {
        kind == .formula ? formulae.contains(qualified) : casks.contains(qualified)
    }

    public static func decode(_ data: Data) throws -> TrustStore {
        try JSONDecoder().decode(TrustStore.self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case taps, formulae, casks, commands
        case trustedTaps = "trustedtaps"
        case trustedFormulae = "trustedformulae"
        case trustedCasks = "trustedcasks"
        case trustedCommands = "trustedcommands"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func names(_ primary: CodingKeys, _ fallback: CodingKeys) -> Set<String> {
            if let v = try? c.decodeIfPresent([String].self, forKey: primary) { return Set(v) }
            if let v = try? c.decodeIfPresent([String].self, forKey: fallback) { return Set(v) }
            return []
        }
        taps = names(.taps, .trustedTaps)
        formulae = names(.formulae, .trustedFormulae)
        casks = names(.casks, .trustedCasks)
        commands = names(.commands, .trustedCommands)
    }
}
