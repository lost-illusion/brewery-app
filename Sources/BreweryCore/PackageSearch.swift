import Foundation

/// A catalog candidate from the core manifest (compat §23: the manifest is
/// core/cask-only — third-party tap packages are browsable in the Taps pane).
public struct CatalogSearchResult: Identifiable, Hashable, Sendable {
    /// Qualified `tap/name` — the exact form `InventoryModel.installItem` accepts.
    public let id: String
    /// Bare formula name / cask token.
    public let name: String
    /// Cask product name when brew carries one ("Google Chrome" for google-chrome).
    public let displayName: String?
    public let kind: BrewItem.Kind
    public let tap: String
    public let latestVersion: String?
    /// Manifest descs are formula-only; casks have none.
    public let desc: String?
    /// Set when the same name+kind is installed (any tap — a tap package sharing
    /// a core name gets the row's installed affordance and its inventory id).
    public let installedItemID: String?
    /// true for candidates sourced from a third-party tap (per-item trust rules
    /// apply to these; core/cask packages never need it).
    public var isExternalTap: Bool { !tap.lowercased().hasPrefix("homebrew/") }
}

/// Local search over the manifest the model already fetched plus the contents
/// lists of installed taps (`tap_info`'s formula_names / cask_tokens, compat §7)
/// — never queries brew per keystroke (compat §3: `brew search` has no JSON and
/// is GitHub-API rate-limited). Sorted by relevance score, name secondarily.
///
/// Tap coverage limits, by design:
/// - only taps with `installed == true` contribute; virtual API taps
///   (homebrew/core, homebrew/cask reported installed:false) would duplicate the
///   manifest with poorer data (compat §7), and a core tap checked out on disk is
///   deduplicated against the manifest, which carries desc + latest version.
/// - no jq → `brew tap` yields names only → tap contents are simply absent.
public func searchCatalog(manifest: PackageManifest?, installed: [BrewItem], taps: [TapInfo],
                          query: String, kind: KindFilter) -> [CatalogSearchResult] {
    let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }

    var installedIDs: [String: String] = [:] // "kind|name" → BrewItem.id
    for item in installed { installedIDs["\(item.kind)|\(item.name.lowercased())"] = item.id }

    var scored: [(score: Int, name: String, result: CatalogSearchResult)] = []

    func consider(name: String, displayName: String?, kind: BrewItem.Kind, tap: String,
                  latest: String?, desc: String?) {
        guard let score = catalogScore(name: name, displayName: displayName, desc: desc, query: q) else { return }
        let installedID = installedIDs["\(kind)|\(name.lowercased())"]
        let result = CatalogSearchResult(id: "\(tap)/\(name)", name: name, displayName: displayName,
                                         kind: kind, tap: tap, latestVersion: latest, desc: desc,
                                         installedItemID: installedID)
        scored.append((score: score, name: name, result: result))
    }

    if let manifest {
        if kind != .casks {
            for (name, entry) in manifest.formulae {
                consider(name: name, displayName: nil, kind: .formula, tap: "homebrew/core",
                         latest: entry.stableVersion, desc: entry.desc)
            }
        }
        if kind != .formulae {
            for (token, entry) in manifest.casks {
                consider(name: token, displayName: entry.name, kind: .cask,
                         tap: entry.tapString ?? "homebrew/cask", latest: entry.version, desc: nil)
            }
        }
    }

    // Third-party tap contents join the same matcher. Names only — tap-info
    // carries no desc/version — so identical-name candidates defer to the
    // richer manifest row (dedup claim covers an on-disk core tap too).
    //
    // Cloned taps report their contents fully qualified ("umputun/apps/revmux")
    // while `brew list` keys installed casks by bare token ("revmux") — compat
    // §106. Normalize with the Taps pane's shared bareName so the name, the dedup
    // claim, and the installed cross-ref all work on the bare string, and the
    // qualified id is recomposed from tap.name — never carried through, which
    // doubles the prefix into an unresolvable "tap/tap/name" brew argument
    // (the 2026-11-02 revmux bug: preview said "No Cask with this name exists"
    // and the installed chip never lit).
    var claimed: Set<String> = []
    if let manifest {
        for name in manifest.formulae.keys { claimed.insert("formula|\(name.lowercased())") }
        for token in manifest.casks.keys { claimed.insert("cask|\(token.lowercased())") }
    }
    for tap in taps where tap.installed {
        if kind != .casks {
            for reported in tap.formulaNames {
                let name = bareName(tap, reported)
                guard !claimed.contains("formula|\(name.lowercased())") else { continue }
                consider(name: name, displayName: nil, kind: .formula, tap: tap.name, latest: nil, desc: nil)
            }
        }
        if kind != .formulae {
            for reported in tap.caskTokens {
                let name = bareName(tap, reported)
                guard !claimed.contains("cask|\(name.lowercased())") else { continue }
                consider(name: name, displayName: nil, kind: .cask, tap: tap.name, latest: nil, desc: nil)
            }
        }
    }

    return scored
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
        .map(\.result)
}

private func catalogScore(name: String, displayName: String?, desc: String?, query: String) -> Int? {
    let n = name.lowercased()
    let d = displayName?.lowercased()
    if n == query { return 1000 }
    if d == query { return 990 }
    if n.hasPrefix(query) { return 900 }
    if d?.hasPrefix(query) == true { return 880 }
    // Token prefix: "chrome" hits google-chrome; names split on -, _, space.
    if n.tokens.contains(where: { $0.hasPrefix(query) }) { return 800 }
    if d?.tokens.contains(where: { $0.hasPrefix(query) }) == true { return 780 }
    if n.contains(query) { return 700 }
    if d?.contains(query) == true { return 650 }
    if isSubsequence(query, in: n) { return 600 }
    if let d, isSubsequence(query, in: d) { return 550 }
    if desc?.lowercased().contains(query) == true { return 400 }
    return nil
}

private extension String {
    var tokens: [String] {
        lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace }).map(String.init)
    }
}

private func isSubsequence(_ needle: String, in haystack: String) -> Bool {
    var it = haystack.lowercased().makeIterator()
    for ch in needle {
        var found = false
        while let next = it.next() {
            if next == ch { found = true; break }
        }
        if !found { return false }
    }
    return true
}
