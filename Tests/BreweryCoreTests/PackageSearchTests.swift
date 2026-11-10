import Foundation
import Testing
@testable import BreweryCore

private func searchManifest() throws -> PackageManifest {
    try PackageManifest.decode(jwsData: fixtureData("manifest-search.json"))
}

/// Installed rows for the cross-ref tests: ripgrep (formula) + iterm2 (cask),
/// list-only merge (no info) so ids are the bare names/tokens.
private func searchInstalled() throws -> [BrewItem] {
    let list = try ListSnapshot.decode(fixtureData("list-search.json"))
    return InventoryMerger.merge(list: list, info: InfoSnapshot(formulae: [], casks: []))
}

private func names(_ results: [CatalogSearchResult]) -> [String] { results.map(\.name) }

@Test func search_exactRanksBeforePrefix() throws {
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: [], query: "git", kind: .all)
    #expect(names(r) == ["git", "gitk"]) // exact 1000 before prefix 900
}

@Test func search_subsequenceTypoTolerance() throws {
    // "rgp" misses every stronger rule for ripgrep but its letters appear in order.
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: [], query: "rgp", kind: .all)
    #expect(names(r) == ["ripgrep"])
}

@Test func search_subsequenceLosesToSubstring() throws {
    // "gre": substring-in-name for ripgrep, subsequence-only for google-chrome.
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: [], query: "gre", kind: .all)
    #expect(names(r) == ["ripgrep", "google-chrome"])
}

@Test func search_descOnlyMatch() throws {
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: [], query: "adventure", kind: .all)
    #expect(names(r) == ["ace"])
}

@Test func search_caskDisplayNameMatch() throws {
    let manifest = try searchManifest()
    // "chrome" hits google-chrome via token prefix; "iterm" hits iterm2 with the
    // display name ("iTerm") as an exact-match alias for the token.
    let chrome = searchCatalog(manifest: manifest, installed: [], taps: [], query: "chrome", kind: .all)
    #expect(names(chrome) == ["google-chrome"])
    let iterm = searchCatalog(manifest: manifest, installed: [], taps: [], query: "iterm", kind: .all)
    #expect(names(iterm) == ["iterm2"])
    #expect(iterm.first?.displayName == "iTerm")
}

@Test func search_kindFilter() throws {
    let manifest = try searchManifest()
    #expect(searchCatalog(manifest: manifest, installed: [], taps: [], query: "iterm", kind: .formulae).isEmpty)
    #expect(names(searchCatalog(manifest: manifest, installed: [], taps: [], query: "iterm", kind: .casks)) == ["iterm2"])
    // "search" lives in ripgrep's desc only.
    #expect(names(searchCatalog(manifest: manifest, installed: [], taps: [], query: "search", kind: .formulae)) == ["ripgrep"])
}

@Test func search_installedCrossRefByNameKind() throws {
    let manifest = try searchManifest()
    let installed = try searchInstalled()
    let ripgrep = searchCatalog(manifest: manifest, installed: installed, taps: [], query: "ripgrep", kind: .all)
    #expect(ripgrep.first?.installedItemID == "ripgrep")
    let iterm = searchCatalog(manifest: manifest, installed: installed, taps: [], query: "iterm", kind: .all)
    #expect(iterm.first?.installedItemID == "iterm2")
    let git = searchCatalog(manifest: manifest, installed: installed, taps: [], query: "git", kind: .all)
    #expect(git.allSatisfy { $0.installedItemID == nil })
}

@Test func search_caseInsensitive() throws {
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: [], query: "WIRE", kind: .all)
    #expect(names(r) == ["wireshark-app"])
}

@Test func search_idsAreQualifiedInstallForms() throws {
    let manifest = try searchManifest()
    let r = searchCatalog(manifest: manifest, installed: [], taps: [], query: "git", kind: .all)
    #expect(r.first?.id == "homebrew/core/git")
    #expect(r.first?.tap == "homebrew/core")
    let cask = searchCatalog(manifest: manifest, installed: [], taps: [], query: "iterm", kind: .all)
    #expect(cask.first?.id == "homebrew/cask/iterm2")
}

/// live-shape tap-info payload (captured from `brew tap-info --installed --json`
/// 2026-11-02): BOTH lists fully qualified, plus a hypothetical bare entry
/// (tolerance) and API-mode taps (installed:false → skipped).
private func searchTaps() throws -> [TapInfo] {
    let json = """
    [
      {"name": "homebrew/core", "installed": true, "official": true, "trusted": true,
       "formula_names": ["homebrew/core/git", "homebrew/core/ace"], "cask_tokens": []},
      {"name": "umputun/apps", "installed": true, "official": false, "trusted": false,
       "formula_names": ["umputun/apps/mpt", "umputun/apps/ralphex", "stray-formula"],
       "cask_tokens": ["umputun/apps/umputun-cask", "umputun/apps/revmux"]},
      {"name": "homebrew/cask", "installed": false, "official": true, "trusted": true,
       "formula_names": [], "cask_tokens": ["homebrew/cask/ghostty"]}
    ]
    """
    return try TapInfo.decode(Data(json.utf8))
}

@Test func search_tapNamesAndTokensIncluded() throws {
    let r = searchCatalog(manifest: try searchManifest(), installed: [], taps: try searchTaps(),
                          query: "mpt", kind: .all)
    #expect(r.first?.id == "umputun/apps/mpt") // exact 1000
    #expect(r.first?.kind == .formula)
    #expect(r.first?.isExternalTap == true)
    // Subsequence fuzzy rule (m→p→t appears in order inside u-M-P-u-T-u-n-cask)
    // drags the cask token in too — documented matcher behavior, exact ranks first.
    #expect(r.map(\.id) == ["umputun/apps/mpt", "umputun/apps/umputun-cask"])
    let cask = searchCatalog(manifest: try searchManifest(), installed: [], taps: try searchTaps(),
                             query: "umputun", kind: .casks)
    #expect(cask.map(\.id) == ["umputun/apps/umputun-cask"])
}

@Test func search_tapInfoQualifiedNamesNormalize() throws {
    // The revmux bug: tap-info says "umputun/apps/revmux", brew list says
    // "revmux". Carrying the qualified string as the name doubled the prefix
    // into "umputun/apps/umputun/apps/revmux" — brew then answered
    // "No Cask with this name exists" and the installed chip never lit.
    let r = searchCatalog(manifest: try searchManifest(), installed: try searchInstalled(),
                          taps: try searchTaps(), query: "revmux", kind: .all)
    #expect(r.count == 1)
    #expect(r.first?.name == "revmux") // bare, matches brew list's token
    #expect(r.first?.id == "umputun/apps/revmux") // single-qualified — brew's accepted argument
    #expect(r.first?.installedItemID == "revmux") // cross-ref against bare list tokens works
    #expect(r.first?.kind == .cask)
    // Bare entries (if a brew build ever reports them) normalize to the same id.
    let stray = searchCatalog(manifest: try searchManifest(), installed: [], taps: try searchTaps(),
                              query: "stray-formula", kind: .all)
    #expect(stray.map(\.id) == ["umputun/apps/stray-formula"])
}

@Test func search_manifestDedupsOnDiskCoreTapAndSkipsApiModeTaps() throws {
    let taps = try searchTaps()
    // homebrew/core is installed:true here — its git/ace must not duplicate the
    // manifest rows (the manifest row wins: it carries desc + version).
    let git = searchCatalog(manifest: try searchManifest(), installed: [], taps: taps,
                            query: "git", kind: .all)
    #expect(git.count == 2) // git + gitk, not git twice
    #expect(git.first?.desc == "Fast, scalable distributed revision control system")
    // ghostty exists only as an API-mode tap token → excluded by design.
    #expect(searchCatalog(manifest: try searchManifest(), installed: [], taps: taps,
                          query: "ghostty", kind: .all).isEmpty)
}

@Test func search_tapsWorkWithoutManifest() throws {
    // A machine with nothing installed has no bottleTag → no manifest; tap
    // contents still search.
    let r = searchCatalog(manifest: nil, installed: [], taps: try searchTaps(),
                          query: "ralphex", kind: .all)
    #expect(r.map(\.id) == ["umputun/apps/ralphex"])
}

@Test func search_caskDescMatch() throws {
    // The manifest carries desc for most casks (5188/7823 live 2026-11-10) —
    // the desc-contains tier reaches casks too.
    let manifest = try searchManifest()
    #expect(names(searchCatalog(manifest: manifest, installed: [], taps: [], query: "emulator", kind: .all)) == ["iterm2"])
    let analyzer = searchCatalog(manifest: manifest, installed: [], taps: [], query: "analyzer", kind: .all)
    #expect(analyzer.map(\.id) == ["homebrew/cask/wireshark-app"])
    #expect(analyzer.first?.desc == "Network protocol analyzer")
}

// MARK: - Alias / rename / tap-migration recall (compat §29)

/// Shape copied from the live payload (2026-11-12): per-entry aliases/oldnames/
/// names, inverted top-level rename maps, migrations whose destination the
/// manifest actually lists — plus a same-name migration (gtkwave) and a
/// core-destination migration (chronograf) that need no entry point at all.
private func aliasManifest() throws -> PackageManifest {
    try PackageManifest.decode(jwsData: fixtureData("manifest-aliases.json"))
}

@Test func search_formulaAlias_recallsAndExplains() throws {
    let manifest = try aliasManifest()
    let r = searchCatalog(manifest: manifest, installed: [], taps: [], query: "golang", kind: .all)
    #expect(r.map(\.id) == ["homebrew/core/go"])
    #expect(r.first?.matchHint == "aka golang")
    // A direct hit on the row's own name never shows a hint.
    let direct = searchCatalog(manifest: manifest, installed: [], taps: [], query: "go", kind: .all)
    #expect(direct.first?.name == "go")
    #expect(direct.first?.matchHint == nil)
    // Versioned formulae alias too: "openssl" finds openssl@4 — but the alias is
    // also a plain prefix of the versioned name (900), and the alias rule scores
    // 1000−100 = 900: tie keeps the direct hit, so no hint. By design.
    let ssl = searchCatalog(manifest: manifest, installed: [], taps: [], query: "openssl", kind: .all)
    #expect(ssl.map(\.id) == ["homebrew/core/openssl@4"])
    #expect(ssl.first?.matchHint == nil)
}

@Test func search_oldnameAndRenameMap_recalls() throws {
    let manifest = try aliasManifest()
    let singularity = searchCatalog(manifest: manifest, installed: [], taps: [], query: "singularity", kind: .all)
    #expect(singularity.map(\.id) == ["homebrew/core/apptainer"])
    #expect(singularity.first?.matchHint == "renamed from singularity")
    // "annie" appears nowhere in formulae — only in the top-level rename map.
    let annie = searchCatalog(manifest: manifest, installed: [], taps: [], query: "annie", kind: .all)
    #expect(annie.map(\.id) == ["homebrew/core/lux"])
    #expect(annie.first?.matchHint == "renamed from annie")
}

@Test func search_caskRenameAndAltNames() throws {
    let manifest = try aliasManifest()
    let amazonq = searchCatalog(manifest: manifest, installed: [], taps: [], query: "amazon-q", kind: .all)
    #expect(amazonq.map(\.id) == ["homebrew/cask/kiro-cli"])
    #expect(amazonq.first?.matchHint == "renamed from amazon-q")
    // "ide" matches the alt product name "Kiro IDE" (token prefix −100 = 680);
    // lux legitimately follows — "ide" is a substring of its desc ("V[ide]o
    // downloader") at 400. Documented matcher behavior, alias ranks first.
    let ide = searchCatalog(manifest: manifest, installed: [], taps: [], query: "ide", kind: .all)
    #expect(ide.map(\.id) == ["homebrew/cask/kiro-cli", "homebrew/core/lux"])
    #expect(ide.first?.matchHint == "aka Kiro IDE")
    // Tie rule: "kiro" hits the token (prefix 900) and the display name — the
    // base match wins the slot, so no hint.
    let kiro = searchCatalog(manifest: manifest, installed: [], taps: [], query: "kiro", kind: .all)
    #expect(kiro.first?.name == "kiro-cli")
    #expect(kiro.first?.matchHint == nil)
}

@Test func search_tapMigration_attachesOldNameToDestinationRow() throws {
    let manifest = try aliasManifest()
    // app-engine-go-32 (formula) → homebrew/cask/app-engine (cask).
    let r = searchCatalog(manifest: manifest, installed: [], taps: [], query: "app-engine-go-32", kind: .all)
    #expect(r.map(\.id) == ["homebrew/cask/app-engine"])
    #expect(r.first?.kind == .cask)
    #expect(r.first?.matchHint == "moved from app-engine-go-32")
}

@Test func search_sameNameOrUnlistedMigration_addsNothing() throws {
    let manifest = try aliasManifest()
    // gtkwave → "homebrew/cask" keeps its name; nothing to recall, and the
    // manifest lists no gtkwave cask — the query finds nothing.
    #expect(searchCatalog(manifest: manifest, installed: [], taps: [], query: "gtkwave", kind: .all).isEmpty)
    // chronograf moved cask→core; the core row already matches by name (no hint).
    let chrono = searchCatalog(manifest: manifest, installed: [], taps: [], query: "chronograf", kind: .all)
    #expect(chrono.map(\.id) == ["homebrew/core/chronograf"])
    #expect(chrono.first?.matchHint == nil)
}

@Test func search_aliasNeverOutranksDirectHits() throws {
    let manifest = try aliasManifest()
    // "kiro-cli" exact-matches the token (1000); the migration/rename aliases
    // sit 100 lower, and rows only reachable via an alias rank below real ones.
    let r = searchCatalog(manifest: manifest, installed: [], taps: [], query: "kiro", kind: .all)
    #expect(r.first?.name == "kiro-cli")
    #expect(r.first?.matchHint == nil)
}

@Test func search_emptyInputsYieldNothing() throws {
    let manifest = try searchManifest()
    #expect(searchCatalog(manifest: manifest, installed: [], taps: [], query: "", kind: .all).isEmpty)
    #expect(searchCatalog(manifest: manifest, installed: [], taps: [], query: "   ", kind: .all).isEmpty)
    #expect(searchCatalog(manifest: nil, installed: [], taps: [], query: "git", kind: .all).isEmpty)
    // Empty manifest (manifest keys missing entirely) must not crash.
    let empty = try PackageManifest.decode(jwsData: Data("{}".utf8))
    #expect(searchCatalog(manifest: empty, installed: [], taps: [], query: "git", kind: .all).isEmpty)
}
