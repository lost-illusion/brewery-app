import Foundation

/// Banner data for deprecated/disabled packages, mirroring the formulae.brew.sh
/// heading title, e.g. "This formula has been disabled since 2026-10-15 because
/// it is deprecated upstream". Disabled wins when both flags are set (the site
/// shows python@3.9 as "(disabled)", compatibilities §49).
public struct DeprecationNotice: Hashable {
    public enum Status: Hashable { case deprecated, disabled }

    public let status: Status
    public let kind: BrewItem.Kind
    public let sinceDate: String?      // kept verbatim: brew's dates are ISO strings
    public let reasonPhrase: String?   // mapped phrase, or the raw string for custom reasons
    public let replacementFormula: String?
    public let replacementCask: String?

    // Phrases copied from Homebrew's DeprecateDisable (Library/Homebrew/deprecate_disable.rb).
    // An unrecognized (formula-crafted) reason falls through verbatim.
    static let formulaReasons: [String: String] = [
        "does_not_build": "does not build",
        "no_license": "has no license",
        "repo_archived": "has an archived upstream repository",
        "repo_removed": "has a removed upstream repository",
        "unmaintained": "is not maintained upstream",
        "unreachable": "is no longer reliably reachable upstream",
        "unsupported": "is not supported upstream",
        "deprecated_upstream": "is deprecated upstream",
        "versioned_formula": "is a versioned formula",
        "checksum_mismatch": "was built with an initially released source file that had a different checksum than the current one",
    ]
    static let caskReasons: [String: String] = [
        "discontinued": "is discontinued upstream",
        "moved_to_mas": "is now exclusively distributed on the Mac App Store",
        "no_longer_available": "is no longer available upstream",
        "no_longer_meets_criteria": "no longer meets the criteria for acceptable casks",
        "unmaintained": "is not maintained upstream",
        "fails_gatekeeper_check": "does not pass the macOS Gatekeeper check",
        "unreachable": "is no longer reliably reachable upstream",
    ]

    public init?(_ item: BrewItem) {
        switch (item.isDisabled, item.isDeprecated) {
        case (true, _): status = .disabled
        case (false, true): status = .deprecated
        default: return nil
        }
        kind = item.kind
        sinceDate = status == .disabled ? item.disableDate ?? item.deprecationDate : item.deprecationDate
        let rawReason = status == .disabled ? item.disabledReason ?? item.deprecationReason : item.deprecationReason
        reasonPhrase = rawReason.map {
            (item.kind == .formula ? Self.formulaReasons : Self.caskReasons)[$0] ?? $0
        }
        replacementFormula = item.replacementFormula
        replacementCask = item.replacementCask
    }

    /// Site-style sentence, e.g. "This formula has been deprecated since 2026-10-01
    /// because it is deprecated upstream." — date/reason clauses appear only when known.
    public var text: String {
        var sentence = "This \(kind == .formula ? "formula" : "cask") has been "
            + (status == .disabled ? "disabled" : "deprecated")
        if let sinceDate { sentence += " since \(sinceDate)" }
        if let reasonPhrase { sentence += " because it \(reasonPhrase)" }
        return sentence + "."
    }

    /// Replacement install command in Homebrew's own wording (DeprecateDisable.message):
    /// a bare name when the formula and cask replacements are identical, else a flag.
    public var replacementCommand: String? {
        if let f = replacementFormula, let c = replacementCask, f == c { return "brew install \(f)" }
        if let f = replacementFormula { return "brew install --formula \(f)" }
        if let c = replacementCask { return "brew install --cask \(c)" }
        return nil
    }
}
