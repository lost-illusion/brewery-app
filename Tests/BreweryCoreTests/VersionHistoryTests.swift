import Foundation
import Testing
@testable import BreweryCore

// MARK: - Fakes

private final class ScriptedExec: ExecRunning, @unchecked Sendable {
    private let results: [String: BrewResult]
    private(set) var calls: [String] = []
    init(results: [String: BrewResult] = [:]) { self.results = results }

    func run(_ executable: URL, _ args: [String]) async throws -> BrewResult {
        let key = executable.path + " " + args.joined(separator: " ")
        calls.append(key)
        await Task.yield()
        guard let result = results[key] else {
            return BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted: \(key)".utf8))
        }
        return result
    }
}

private final class FakeGitHubJSON: GitHubJSONFetching, @unchecked Sendable {
    private let handler: @Sendable (URL, String?) async throws -> Data
    private(set) var requests: [(url: URL, token: String?)] = []
    init(handler: @escaping @Sendable (URL, String?) async throws -> Data) { self.handler = handler }

    func gitHubJSON(url: URL, token: String?) async throws -> Data {
        requests.append((url, token))
        return try await handler(url, token)
    }
}

private func brewOK(_ stdout: String) -> BrewResult {
    BrewResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
}
private func brewFail(_ stderr: String) -> BrewResult {
    BrewResult(exitCode: 1, stdout: Data(), stderr: Data(stderr.utf8))
}

private func item(_ name: String, kind: BrewItem.Kind = .formula, tap: String? = "homebrew/core",
                  homepage: String? = nil) -> BrewItem {
    BrewItem(id: name, kind: kind, name: name, fullName: name, tap: tap,
             installedVersions: ["1.0"], linkedVersion: "1.0", optlinkedVersion: nil, pinnedVersion: nil,
             latestVersion: nil, outdated: nil, infoOutdated: nil, infoVersion: nil, isPinned: false, isDeprecated: false, deprecationReason: nil,
             isDisabled: false, disabledReason: nil, deprecationDate: nil, disableDate: nil,
             replacementFormula: nil, replacementCask: nil, desc: nil, homepage: homepage, installedAt: nil,
             kegOnly: false, autoUpdates: false, dependencies: [], sourceState: .complete)
}

/// A cloned tap shaped like `brew tap-info --installed --json` on umputun/apps
/// (verified 2026-10-30): absolute definition file paths under Formula/ and Casks/.
private func clonedTap(_ name: String = "umputun/apps", installed: Bool = true) -> TapInfo {
    let dir = "/opt/homebrew/Library/Taps/umputun/homebrew-apps"
    return TapInfoDecoderStub.make(tapName: name, installed: installed, directory: dir,
                                   formulaFiles: ["\(dir)/Formula/cronn.rb"],
                                   caskFiles: ["\(dir)/Casks/agterm.rb"])
}

/// TapInfo has no public field-by-field init (the decoder is the real seam);
/// decode a JSON doc instead — same shape brew emits.
private enum TapInfoDecoderStub {
    static func make(tapName: String, installed: Bool, directory: String,
                     formulaFiles: [String], caskFiles: [String]) -> TapInfo {
        let json: [String: Any] = [
            "name": tapName, "user": tapName.split(separator: "/")[0], "repo": "apps",
            "path": directory, "installed": installed, "official": false, "trusted": false,
            "formula_names": formulaFiles.map { "\(tapName)/\(($0 as NSString).lastPathComponent.dropLast(3))" },
            "cask_tokens": caskFiles.map { "\(tapName)/\(($0 as NSString).lastPathComponent.dropLast(3))" },
            "formula_files": formulaFiles, "cask_files": caskFiles, "command_files": [String](),
        ]
        let data = try! JSONSerialization.data(withJSONObject: [json])
        return try! TapInfo.decode(data)[0]
    }
}

// MARK: - Definition paths (bucket rules from CoreTap/CoreCaskTap, verified live)

@Test func definitionPath_formulaBuckets() {
    #expect(coreFormulaDefinitionPath(name: "wget") == "Formula/w/wget.rb")
    #expect(coreFormulaDefinitionPath(name: "openssl@3") == "Formula/o/openssl@3.rb")
    #expect(coreFormulaDefinitionPath(name: "libgit2") == "Formula/lib/libgit2.rb")
    #expect(coreFormulaDefinitionPath(name: "libpng") == "Formula/lib/libpng.rb")
    // "liquidsoap" starts liq-, not lib-: stays in the letter bucket.
    #expect(coreFormulaDefinitionPath(name: "liquidsoap") == "Formula/l/liquidsoap.rb")
}

@Test func definitionPath_caskBuckets() {
    #expect(coreCaskDefinitionPath(token: "wireshark-app") == "Casks/w/wireshark-app.rb")
    #expect(coreCaskDefinitionPath(token: "0ad") == "Casks/0/0ad.rb") // digit directories exist
    #expect(coreCaskDefinitionPath(token: "font-fira-code") == "Casks/font/font-f/font-fira-code.rb")
}

// MARK: - Routing

@Test func route_coreItemsGoToGitHub() {
    let f = historyRoute(for: item("openssl@3"), taps: [])
    #expect(f == .github(repo: coreFormulaRepo, path: "Formula/o/openssl@3.rb"))
    let c = historyRoute(for: item("wireshark-app", kind: .cask, tap: "homebrew/cask"), taps: [])
    #expect(c == .github(repo: coreCaskRepo, path: "Casks/w/wireshark-app.rb"))
    // Unknown-tap rows follow the brewPageURL guess: official repo by kind.
    let n = historyRoute(for: item("wget", tap: nil), taps: [])
    #expect(n == .github(repo: coreFormulaRepo, path: "Formula/w/wget.rb"))
}

@Test func route_clonedTapUsesPerFileGit() {
    let taps = [clonedTap()]
    let route = historyRoute(for: item("agterm", kind: .cask, tap: "umputun/apps"), taps: taps)
    #expect(route == .tapGit(tapDirectory: "/opt/homebrew/Library/Taps/umputun/homebrew-apps",
                             file: "Casks/agterm.rb"))
    #expect(historyRouteNeedsTaps(for: item("agterm", kind: .cask, tap: "umputun/apps")))
    #expect(!historyRouteNeedsTaps(for: item("wget"))) // core rows route without taps
}

@Test func route_tapFailuresStateTheReason() {
    // Virtual API-mode taps report installed: false (§21).
    let virtual = historyRoute(for: item("agterm", kind: .cask, tap: "umputun/apps"), taps: [clonedTap(installed: false)])
    if case .unsupported(let reason) = virtual { #expect(reason.contains("not cloned on disk")) } else { Issue.record("expected unsupported") }
    let missing = historyRoute(for: item("agterm", kind: .cask, tap: "bob/other"), taps: [clonedTap()])
    if case .unsupported(let reason) = missing { #expect(reason.contains("not in the tap list")) } else { Issue.record("expected unsupported") }
    let noFile = historyRoute(for: item("ghost", kind: .formula, tap: "umputun/apps"), taps: [clonedTap()])
    if case .unsupported(let reason) = noFile { #expect(reason.contains("No definition file")) } else { Issue.record("expected unsupported") }
}

// MARK: - Version bump subjects

@Test func versionBump_bareSubjectsOnly() {
    #expect(versionBump(in: "ace 8.0.8", name: "ace") == "8.0.8")
    #expect(versionBump(in: "openssl@3 3.5.9 (downgrade to LTS)", name: "openssl@3") == "3.5.9")
    #expect(versionBump(in: "wget 1.25.0_1", name: "wget") == "1.25.0_1")
    #expect(versionBump(in: "agterm 0.39.1", name: "agterm") == "0.39.1") // tap author, same shape
    #expect(versionBump(in: "ace: update 8.0.8 bottle.", name: "ace") == nil)
    #expect(versionBump(in: "wget: migrate to `openssl@4`", name: "wget") == nil)
    #expect(versionBump(in: "Brew formula update for reproxy version v1.7.2", name: "reproxy") == nil)
    #expect(versionBump(in: "ace2 1.0", name: "ace") == nil) // prefix collision
}

// MARK: - GitHub commits JSON decode

@Test func decodeGitHubCommits_realPayloadShape() throws {
    // Layout as returned by commits-by-path on 2026-10-30 (wget probe).
    let json = """
    [
      {"sha":"95f2696a","html_url":"https://github.com/Homebrew/homebrew-core/commit/95f2696a",
       "commit":{"message":"wget: update 1.25.0_2 bottle.\\n\\nCo-Authored-By: Bot <bot@example.com>",
                 "author":{"date":"2026-09-22T12:34:43Z"}}},
      {"sha":"5f59974c","html_url":"https://github.com/Homebrew/homebrew-core/commit/5f59974c",
       "commit":{"message":"wget 1.25.0\\n\\nSome body line.","author":{"date":"2026-09-21T12:02:03Z"}}},
      {"sha":"nope","commit":{"message":null,"author":{"date":null}}}
    ]
    """
    let entries = try decodeGitHubCommits(Data(json.utf8), name: "wget")
    #expect(entries.count == 2) // malformed entry skipped, list still served
    #expect(entries[0].subject == "wget: update 1.25.0_2 bottle.") // first line only
    #expect(entries[0].versionBump == nil)
    #expect(entries[0].webURL?.absoluteString == "https://github.com/Homebrew/homebrew-core/commit/95f2696a")
    #expect(entries[1].versionBump == "1.25.0")
    #expect(entries[1].id == "5f59974c")
    let formatter = ISO8601DateFormatter()
    #expect(entries[0].date == formatter.date(from: "2026-09-22T12:34:43Z"))
}

@Test func decodeGitHubCommits_rejectsNonArray() {
    #expect(throws: VersionHistoryError.self) {
        try decodeGitHubCommits(Data("{\"message\":\"bad\"}".utf8), name: "wget")
    }
}

// MARK: - Tap git log decode

@Test func decodeTapGitLog_unitSeparatedPrettyFormat() {
    let s = gitFieldSeparator
    // Verbatim shape from `git -C …/homebrew-apps log --date=iso-strict --pretty=…` (2026-10-30).
    let text = "c0665f6c\(s)2026-10-30T01:13:44-05:00\(s)agterm 0.39.1\n"
        + "48f30bcb\(s)2026-10-23T11:10:26-05:00\(s)agterm: strip the quarantine before the move\n"
    let entries = decodeTapGitLog(text, name: "agterm")
    #expect(entries.count == 2)
    #expect(entries[0].id == "c0665f6c")
    #expect(entries[0].versionBump == "0.39.1")
    #expect(entries[0].webURL == nil) // no commitBase: linkless rows
    #expect(entries[1].versionBump == nil)
    #expect(entries[0].date != nil) // iso-strict with a numeric offset parses
}

@Test func decodeTapGitLog_commitBaseLinksEachSha() {
    let s = gitFieldSeparator
    let text = "c0665f6c\(s)2026-10-30T01:13:44-05:00\(s)agterm 0.39.1"
    let entries = decodeTapGitLog(text, name: "agterm",
                                  commitBase: "https://github.com/umputun/homebrew-apps/commit/")
    #expect(entries[0].webURL?.absoluteString == "https://github.com/umputun/homebrew-apps/commit/c0665f6c")
}

@Test func githubRepoFromGitRemote_acceptedForms() {
    func pair(_ s: String) -> [String] {
        guard let r = githubRepoFromGitRemote(s) else { return [] }
        return [r.owner, r.repo]
    }
    #expect(pair("https://github.com/umputun/homebrew-apps.git\n") == ["umputun", "homebrew-apps"])
    #expect(pair("git@github.com:umputun/homebrew-apps.git") == ["umputun", "homebrew-apps"])
    #expect(pair("ssh://git@github.com/acme/homebrew-tools") == ["acme", "homebrew-tools"])
    #expect(pair("https://github.com/acme/tari") == ["acme", "tari"])
    #expect(pair("https://gitlab.com/acme/tap.git") == [])
    #expect(pair("") == [])
    #expect(pair("https://github.com/onlyowner") == [])
}

// MARK: - Fetcher

private func fetcher(access: VersionHistoryFetcher.Access, gitURL: URL? = URL(fileURLWithPath: "/fake/git"),
                     ghURL: URL? = URL(fileURLWithPath: "/fake/gh"),
                     exec: ExecRunning = ScriptedExec(),
                     github: GitHubJSONFetching = FakeGitHubJSON { _, _ in Data("[]".utf8) }) -> VersionHistoryFetcher {
    VersionHistoryFetcher(access: access, gitURL: gitURL, ghURL: ghURL, exec: exec, github: github)
}

@Test func fetch_offSourceNamesTheSettingsPane() async {
    let f = fetcher(access: .init())
    await #expect(throws: VersionHistoryError(message: "Version history is off — pick a GitHub source in Settings → Changelogs.")) {
        try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/w/wget.rb"), name: "wget")
    }
}

@Test func fetch_tokenModePassesURLAndToken() async throws {
    var access = VersionHistoryFetcher.Access()
    access.source = .token
    access.token = " ghp_test "
    let github = FakeGitHubJSON { _, _ in Data(#"[{"sha":"a","commit":{"message":"wget 1.0","author":{"date":"2026-01-01T00:00:00Z"}}}]"#.utf8) }
    let f = fetcher(access: access, github: github)
    let entries = try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/w/wget.rb"), name: "wget")
    #expect(entries.first?.versionBump == "1.0")
    #expect(github.requests.count == 1)
    #expect(github.requests[0].token == "ghp_test") // trimmed
    // URLComponents keeps "/" literal in query items — the exact form the live
    // commits-by-path probe used on 2026-10-30.
    #expect(github.requests[0].url.absoluteString.contains("path=Formula/w/wget.rb"))
    #expect(github.requests[0].url.absoluteString.contains("per_page=30"))
}

@Test func fetch_tokenModeWithoutTokenFails() async {
    var access = VersionHistoryFetcher.Access()
    access.source = .token
    let f = fetcher(access: access)
    await #expect(throws: VersionHistoryError(message: "No GitHub token set — add one in Settings → Changelogs.")) {
        try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/w/wget.rb"), name: "wget")
    }
}

@Test func fetch_ghCLIRunsTheVerifiedCommandShape() async throws {
    var access = VersionHistoryFetcher.Access()
    access.source = .ghCLI
    let args = VersionHistoryFetcher.ghArguments(apiPath: "repos/Homebrew/homebrew-core/commits",
                                                 params: [("path", "Formula/o/openssl@3.rb"), ("per_page", "30")])
    let key = "/fake/gh " + args.joined(separator: " ")
    let exec = ScriptedExec(results: [key: brewOK(#"[{"sha":"b","commit":{"message":"openssl@3 3.5.9","author":{"date":"2026-01-01T00:00:00Z"}}}]"#)])
    let f = fetcher(access: access, exec: exec)
    let entries = try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/o/openssl@3.rb"), name: "openssl@3")
    #expect(entries.first?.versionBump == "3.5.9")
    // gh defaults to POST when -f params are present: -X GET must stay explicit.
    #expect(exec.calls == [key])
    #expect(args.prefix(3) == ["api", "repos/Homebrew/homebrew-core/commits", "-X"])
}

@Test func fetch_ghCLISurfacesGhOwnErrorWording() async {
    var access = VersionHistoryFetcher.Access()
    access.source = .ghCLI
    let exec = ScriptedExec(results: ["/fake/gh api repos/Homebrew/homebrew-core/commits -X GET -f path=Formula/w/ghost.rb -f per_page=30":
                                        brewFail("gh: Not Found (HTTP 404)")])
    let f = fetcher(access: access, exec: exec)
    await #expect(throws: VersionHistoryError(message: "gh: Not Found (HTTP 404)")) {
        try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/w/ghost.rb"), name: "ghost")
    }
}

@Test func fetch_ghCLIWhenMissingNamesTheInstallFix() async {
    var access = VersionHistoryFetcher.Access()
    access.source = .ghCLI
    let f = fetcher(access: access, ghURL: nil)
    await #expect(throws: VersionHistoryError(message: "gh not found — install it with `brew install gh`.")) {
        try await f.fetch(route: .github(repo: coreFormulaRepo, path: "Formula/w/wget.rb"), name: "wget")
    }
}

@Test func fetch_tapGitRunsGitOnTapRelativeFile() async throws {
    let s = gitFieldSeparator
    let route = HistoryRoute.tapGit(tapDirectory: "/tap", file: "Formula/tool.rb")
    let args = ["-C", "/tap", "log", "--max-count=30", "--date=iso-strict",
                "--pretty=format:%H\(s)%ad\(s)%s", "--", "Formula/tool.rb"]
    let logKey = "/fake/git " + args.joined(separator: " ")
    // Non-GitHub origin: the history loads, but no commit links are invented.
    let remoteKey = "/fake/git -C /tap remote get-url origin"
    let exec = ScriptedExec(results: [logKey: brewOK("aaa\(s)2026-01-01T00:00:00Z\(s)tool 1.0"),
                                      remoteKey: brewOK("https://gitlab.com/acme/tap.git")])
    let f = fetcher(access: .init(), exec: exec) // source .off: tap git needs no GitHub source
    let entries = try await f.fetch(route: route, name: "tool")
    #expect(entries.first?.versionBump == "1.0")
    #expect(entries.first?.webURL == nil)
    #expect(exec.calls == [logKey, remoteKey])
}

@Test func fetch_tapGitLinksCommitsViaGithubOrigin() async throws {
    let s = gitFieldSeparator
    let route = HistoryRoute.tapGit(tapDirectory: "/tap", file: "Casks/agterm.rb")
    let args = ["-C", "/tap", "log", "--max-count=30", "--date=iso-strict",
                "--pretty=format:%H\(s)%ad\(s)%s", "--", "Casks/agterm.rb"]
    let exec = ScriptedExec(results: [
        "/fake/git " + args.joined(separator: " "): brewOK("aaa\(s)2026-01-01T00:00:00Z\(s)agterm 0.39.1"),
        "/fake/git -C /tap remote get-url origin": brewOK("git@github.com:umputun/homebrew-apps.git"),
    ])
    let f = fetcher(access: .init(), exec: exec)
    let entries = try await f.fetch(route: route, name: "agterm")
    #expect(entries.first?.webURL?.absoluteString == "https://github.com/umputun/homebrew-apps/commit/aaa")
}

@Test func fetch_tapGitToleratesMissingRemote() async throws {
    let s = gitFieldSeparator
    let route = HistoryRoute.tapGit(tapDirectory: "/tap", file: "Formula/tool.rb")
    let args = ["-C", "/tap", "log", "--max-count=30", "--date=iso-strict",
                "--pretty=format:%H\(s)%ad\(s)%s", "--", "Formula/tool.rb"]
    // Only the log scripted: the remote probe comes back unscripted (exit 1)
    // and must not sink the history — linkless rows instead.
    let exec = ScriptedExec(results: ["/fake/git " + args.joined(separator: " "): brewOK("aaa\(s)2026-01-01T00:00:00Z\(s)tool 1.0")])
    let f = fetcher(access: .init(), exec: exec)
    let entries = try await f.fetch(route: route, name: "tool")
    #expect(entries.first?.versionBump == "1.0")
    #expect(entries.first?.webURL == nil)
}

@Test func fetch_tapGitWhenGitMissingNamesCLT() async {
    let f = fetcher(access: .init(), gitURL: nil)
    await #expect(throws: VersionHistoryError(message: "git not found — run `xcode-select --install` for the Command Line Tools.")) {
        try await f.fetch(route: .tapGit(tapDirectory: "/tap", file: "Formula/tool.rb"), name: "tool")
    }
}

@Test func fetch_unsupportedRouteStatesReason() async {
    let f = fetcher(access: .init())
    await #expect(throws: VersionHistoryError(message: "Tap x/y is not cloned on disk (API mode) — no local git history.")) {
        try await f.fetch(route: .unsupported(reason: "Tap x/y is not cloned on disk (API mode) — no local git history."), name: "tool")
    }
}

// MARK: - Upstream releases

@Test func upstreamReleaseURL_matchesBumpIgnoringLeadingV() {
    let releases = [
        UpstreamRelease(id: "u1", tag: "v0.39.1", title: nil, publishedAt: nil,
                        webURL: URL(string: "https://github.com/umputun/agterm/releases/tag/v0.39.1"),
                        isPrerelease: false, bodyText: nil),
        UpstreamRelease(id: "u2", tag: "0.38.0", title: nil, publishedAt: nil,
                        webURL: URL(string: "https://github.com/umputun/agterm/releases/tag/0.38.0"),
                        isPrerelease: false, bodyText: "- shipped notes"),
    ]
    // bump "0.39.1" from the tap log must find the upstream tag "v0.39.1".
    #expect(upstreamReleaseURL(matching: "0.39.1", in: releases)?.path.hasSuffix("/v0.39.1") == true)
    #expect(upstreamReleaseURL(matching: "0.38.0", in: releases)?.path.hasSuffix("/0.38.0") == true)
    #expect(upstreamReleaseURL(matching: "9.9.9", in: releases) == nil)
    // The merged detail list needs the release itself (title/pre-release),
    // not just the URL; unmatched versions stay nil so they get their own row.
    #expect(upstreamRelease(matching: "0.39.1", in: releases)?.tag == "v0.39.1")
    #expect(upstreamRelease(matching: "9.9.9", in: releases) == nil)
}

/// Shape verified live 2026-10-30 against repos/umputun/agterm/releases.
private let releasesJSON = """
[
  {"tag_name":"v0.39.1","name":"Version 0.39.1",
   "body":"### Improved\\n\\n- the GUI `ask` dialog matches the box","published_at":"2026-10-30T06:13:39Z",
   "html_url":"https://github.com/umputun/agterm/releases/tag/v0.39.1","draft":false,"prerelease":false},
  {"tag_name":"v0.40.0-rc1","name":null,"published_at":"2026-10-29T06:00:00Z",
   "html_url":"https://github.com/umputun/agterm/releases/tag/v0.40.0-rc1","draft":false,"prerelease":true},
  {"tag_name":"wip","name":"author work in progress","html_url":"https://github.com/umputun/agterm/releases/tag/wip",
   "draft":true,"prerelease":false}
]
"""

@Test func decodeGitHubReleases_dropsDraftsKeepsPrereleases() throws {
    let releases = try decodeGitHubReleases(Data(releasesJSON.utf8))
    #expect(releases.count == 2) // draft dropped: author work, not a changelog entry
    #expect(releases[0].tag == "v0.39.1")
    #expect(releases[0].title == "Version 0.39.1")
    #expect(releases[0].webURL?.absoluteString == "https://github.com/umputun/agterm/releases/tag/v0.39.1")
    #expect(releases[0].publishedAt != nil)
    #expect(releases[1].isPrerelease)
    #expect(releases[1].title == nil) // null name → tag stands alone
    // The releases-list payload carries `body` too (probed live 2026-10-30):
    // the modal renders it without a second API call.
    #expect(releases[0].bodyText?.hasPrefix("### Improved") == true)
    #expect(releases[1].bodyText == nil) // no body key → no changelog button
}

@Test func decodeGitHubReleases_bodyTrimmedBlankBecomesNil() throws {
    let json = """
    [
      {"tag_name":"v1","body":"  ## Notes\\n\\n- a  "},
      {"tag_name":"v2","body":"   \\n "},
      {"tag_name":"v3","body":null}
    ]
    """
    let releases = try decodeGitHubReleases(Data(json.utf8))
    #expect(releases[0].bodyText == "## Notes\n\n- a")
    #expect(releases[1].bodyText == nil) // whitespace body is not a changelog
    #expect(releases[2].bodyText == nil)
}

@Test func decodeGitHubReleases_rejectsNonArray() {
    #expect(throws: VersionHistoryError.self) {
        try decodeGitHubReleases(Data("{\"message\":\"bad\"}".utf8))
    }
}

@Test func fetchReleases_tokenModeHitsReleasesEndpoint() async throws {
    var access = VersionHistoryFetcher.Access()
    access.source = .token
    access.token = "ghp_test"
    let github = FakeGitHubJSON { _, _ in Data(releasesJSON.utf8) }
    let f = fetcher(access: access, github: github)
    let releases = try await f.fetchReleases(owner: "umputun", repo: "agterm")
    #expect(releases.count == 2)
    #expect(github.requests[0].url.absoluteString.contains("repos/umputun/agterm/releases"))
    #expect(github.requests[0].url.absoluteString.contains("per_page=10"))
}

@Test func fetchReleases_ghCLIUsesTheSameGETForm() async throws {
    var access = VersionHistoryFetcher.Access()
    access.source = .ghCLI
    let args = ["api", "repos/umputun/agterm/releases", "-X", "GET", "-f", "per_page=10"]
    let exec = ScriptedExec(results: ["/fake/gh " + args.joined(separator: " "): brewOK(releasesJSON)])
    let f = fetcher(access: access, exec: exec)
    let releases = try await f.fetchReleases(owner: "umputun", repo: "agterm")
    #expect(releases.first?.tag == "v0.39.1")
    #expect(exec.calls == ["/fake/gh " + args.joined(separator: " ")])
}

// MARK: - Upstream release notes

@Test func releaseNotes_githubHomepagesOnly() {
    #expect(releaseNotesURL(for: item("reproxy", homepage: "https://github.com/umputun/reproxy"))?
        .absoluteString == "https://github.com/umputun/reproxy/releases")
    #expect(releaseNotesURL(for: item("x", homepage: "https://www.github.com/foo/bar/"))?
        .absoluteString == "https://github.com/foo/bar/releases")
    #expect(releaseNotesURL(for: item("x", homepage: "https://github.com/foo/bar.git"))?
        .absoluteString == "https://github.com/foo/bar/releases")
    #expect(releaseNotesURL(for: item("wget", homepage: "https://www.gnu.org/software/wget/")) == nil)
    #expect(releaseNotesURL(for: item("x", homepage: "https://github.com/only-owner")) == nil)
    #expect(releaseNotesURL(for: item("x")) == nil) // no homepage at all
}

// MARK: - Model

private func tokenFetcher(json: @escaping @Sendable () async throws -> Data) -> (VersionHistoryFetcher, FakeGitHubJSON) {
    let fake = FakeGitHubJSON { _, _ in try await json() }
    var access = VersionHistoryFetcher.Access()
    access.source = .token
    access.token = "ghp_test"
    return (fetcher(access: access, github: fake), fake)
}

@MainActor @Test func model_loadCachesPerItemAndForceBypasses() async throws {
    let (f, fake) = tokenFetcher { Data(#"[{"sha":"a","commit":{"message":"wget 1.0","author":{"date":"2026-01-01T00:00:00Z"}}}]"#.utf8) }
    let model = VersionHistoryModel(fetcher: f)
    let wget = item("wget")
    await model.load(for: wget, taps: [])
    if case .loaded(let entries, let origin, _) = model.status(for: wget) {
        #expect(entries.count == 1)
        #expect(origin == "GitHub \(coreFormulaRepo) · Formula/w/wget.rb")
    } else { Issue.record("expected loaded") }
    await model.load(for: wget, taps: []) // cached within TTL
    #expect(fake.requests.count == 1)
    await model.load(for: wget, taps: [], force: true)
    #expect(fake.requests.count == 2)
}

@MainActor @Test func model_failureIsPerItemStatus() async {
    let (f, _) = tokenFetcher { throw VersionHistoryError(message: "GitHub: rate limit exceeded") }
    let model = VersionHistoryModel(fetcher: f)
    await model.load(for: item("wget"), taps: [])
    #expect(model.status(for: item("wget")) == .failed(message: "GitHub: rate limit exceeded"))
    #expect(model.status(for: item("curl")) == .idle) // other pages unaffected
}

@MainActor @Test func model_configureInvalidatesCachesAndReplacesAccess() async throws {
    let (f, fake) = tokenFetcher { Data("[]".utf8) }
    let model = VersionHistoryModel(fetcher: f)
    await model.load(for: item("wget"), taps: [])
    #expect(fake.requests.count == 1)
    model.configure(source: .off, token: "")
    #expect(model.status(for: item("wget")) == .idle) // old attempt must not survive a source flip
    await model.load(for: item("wget"), taps: []) // .off → refused, no request
    #expect(fake.requests.count == 1)
    model.configure(source: .token, token: "ghp_test") // no-op when unchanged
    await model.load(for: item("wget"), taps: [])
    #expect(fake.requests.count == 2)
}

@MainActor @Test func model_releasesLoadCacheAndSkipNonGithubHomepages() async throws {
    let (f, fake) = tokenFetcher { Data(releasesJSON.utf8) }
    let model = VersionHistoryModel(fetcher: f)
    let agterm = item("agterm", homepage: "https://github.com/umputun/agterm")
    await model.loadReleases(for: agterm)
    if case .loaded(let releases) = model.releaseStatus(for: agterm) {
        #expect(releases.count == 2)
    } else { Issue.record("expected loaded") }
    await model.loadReleases(for: agterm) // cached within TTL
    #expect(fake.requests.count == 1)
    await model.loadReleases(for: agterm, force: true)
    #expect(fake.requests.count == 2)
    // GNU-homepage upstreams have no structured release source (§21) → no fetch, idle.
    await model.loadReleases(for: item("wget", homepage: "https://www.gnu.org/software/wget/"))
    #expect(fake.requests.count == 2)
    #expect(model.releaseStatus(for: item("wget", homepage: "https://www.gnu.org/software/wget/")) == .idle)
    model.configure(source: .off, token: "")
    #expect(model.releaseStatus(for: agterm) == .idle) // releases follow the source flip too
}
