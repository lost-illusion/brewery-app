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
    /// Why a query that isn't the row's name surfaced it: "aka golang",
    /// "renamed from singularity", "moved from app-engine-go-32". nil when the
    /// row matched by its own name/display name (a direct hit never shows a hint).
    public let matchHint: String?
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
/// `aliases` lets callers reuse a precomputed manifestAliasIndex (the model does
/// this per refresh); nil builds one for this query.
public func searchCatalog(manifest: PackageManifest?, installed: [BrewItem], taps: [TapInfo],
                          query: String, kind: KindFilter,
                          aliases: [String: [AliasTerm]]? = nil) -> [CatalogSearchResult] {
    let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }

    var installedIDs: [String: String] = [:] // "kind|name" → BrewItem.id
    for item in installed { installedIDs["\(item.kind)|\(item.name.lowercased())"] = item.id }

    var scored: [(score: Int, name: String, result: CatalogSearchResult)] = []

    func consider(name: String, displayName: String?, kind: BrewItem.Kind, tap: String,
                  latest: String?, desc: String?, aliases: [AliasTerm] = []) {
        var best = catalogScore(name: name, displayName: displayName, desc: desc, query: q)
        var hint: String?
        // Alias entry points score 100 below their raw tier: a direct hit on the
        // row's own name (or a tie with one) always wins the slot, so the alias
        // machinery only adds rows nothing else matched — and explains them.
        var seen: Set<String> = [name.lowercased()]
        if let displayName { seen.insert(displayName.lowercased()) }
        for alias in aliases where seen.insert(alias.term.lowercased()).inserted {
            guard let score = catalogScore(name: alias.term, displayName: nil, desc: nil, query: q) else { continue }
            if score - 100 > (best ?? -1) { best = score - 100; hint = alias.hint }
        }
        guard let best else { return }
        let installedID = installedIDs["\(kind)|\(name.lowercased())"]
        let result = CatalogSearchResult(id: "\(tap)/\(name)", name: name, displayName: displayName,
                                         kind: kind, tap: tap, latestVersion: latest, desc: desc,
                                         installedItemID: installedID, matchHint: hint)
        scored.append((score: best, name: name, result: result))
    }

    let aliasIndex = aliases ?? (manifest.map(manifestAliasIndex) ?? [:])
    if let manifest {
        if kind != .casks {
            for (name, entry) in manifest.formulae {
                consider(name: name, displayName: nil, kind: .formula, tap: "homebrew/core",
                         latest: entry.stableVersion, desc: entry.desc,
                         aliases: aliasIndex["formula|\(name.lowercased())"] ?? [])
            }
        }
        if kind != .formulae {
            for (token, entry) in manifest.casks {
                consider(name: token, displayName: entry.name, kind: .cask,
                         tap: entry.tapString ?? "homebrew/cask", latest: entry.version, desc: nil,
                         aliases: aliasIndex["cask|\(token.lowercased())"] ?? [])
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

/// One alternate name a row also answers to, plus the caption explaining it.
public struct AliasTerm: Hashable, Sendable {
    public let term: String
    public let hint: String
    public init(term: String, hint: String) { self.term = term; self.hint = hint }
}

/// Alternate names per installed/catalog row, keyed `"\(kind)|\(name)"` — the
/// same key shape InventoryModel's installed cross-ref uses. Built once per
/// manifest (not per query): the Install pane's scorer and the Installed pane's
/// filter share it, so "golang" finds installed `go` too. Payload semantics:
/// compat §29.
public func manifestAliasIndex(_ manifest: PackageManifest) -> [String: [AliasTerm]] {
    var index: [String: [AliasTerm]] = [:]
    func add(_ kind: BrewItem.Kind, _ name: String, _ term: AliasTerm) {
        index["\(kind)|\(name.lowercased())", default: []].append(term)
    }
    for (name, entry) in manifest.formulae {
        for alias in entry.aliases { add(.formula, name, AliasTerm(term: alias, hint: "aka \(alias)")) }
        for old in entry.oldnames { add(.formula, name, AliasTerm(term: old, hint: "renamed from \(old)")) }
    }
    for (token, entry) in manifest.casks {
        let display = entry.name?.lowercased()
        for alt in entry.names ?? [] where alt.lowercased() != token.lowercased() && alt.lowercased() != display {
            add(.cask, token, AliasTerm(term: alt, hint: "aka \(alt)"))
        }
    }
    for (old, new) in manifest.formulaRenames where new != old {
        add(.formula, new, AliasTerm(term: old, hint: "renamed from \(old)"))
    }
    for (old, new) in manifest.caskRenames where new != old {
        add(.cask, new, AliasTerm(term: old, hint: "renamed from \(old)"))
    }
    // Migrations attach the old identifier to the destination row of the
    // opposite kind — but only when the manifest lists the destination (the app
    // can only preview/install what the catalog holds). Same-name migrations
    // need no entry: the destination already matches by name.
    for (old, destination) in manifest.formulaTapMigrations {
        let (tap, name) = migrationTarget(destination, fallbackName: old)
        guard name != old, manifest.casks[name] != nil, tap.lowercased().hasPrefix("homebrew/cask") else { continue }
        add(.cask, name, AliasTerm(term: old, hint: "moved from \(old)"))
    }
    for (old, destination) in manifest.caskTapMigrations {
        let (tap, name) = migrationTarget(destination, fallbackName: old)
        guard name != old, manifest.formulae[name] != nil, !tap.lowercased().hasPrefix("homebrew/cask") else { continue }
        add(.formula, name, AliasTerm(term: old, hint: "moved from \(old)"))
    }
    return index
}

/// Splits a migration destination ("homebrew/cask" keeps the name;
/// "homebrew/cask/app-engine" renames too) into (tap, package name).
private func migrationTarget(_ destination: String, fallbackName: String) -> (tap: String, name: String) {
    let parts = destination.split(separator: "/").map(String.init)
    guard parts.count >= 3 else { return (destination, fallbackName) }
    let tap = parts.prefix(2).joined(separator: "/")
    let name = parts.dropFirst(2).joined(separator: "/")
    return (tap, name)
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
