import Foundation

// MARK: - Entries

/// One packaging commit in a package's history (§21): a homebrew-core /
/// homebrew-cask commit touching the definition file, or a local tap git
/// commit. `versionBump` carries the version when the subject is a bare
/// `<name> <version>` bump; `webURL` exists for GitHub entries only.
public struct VersionHistoryEntry: Identifiable, Hashable, Sendable {
    public let id: String // commit sha
    public let subject: String // first line of the commit message
    public let date: Date?
    public let versionBump: String?
    public let webURL: URL?
}

/// Homebrew's version-bump subjects are bare (`ace 8.0.8`,
/// `openssl@3 3.5.9 (downgrade to LTS)`); everything else prefixes the name
/// with a colon (`ace: update 8.0.8 bottle.`) — compat §21. Tap authors are
/// unguaranteed, so a no-match just means "not recognized as a bump".
public func versionBump(in subject: String, name: String) -> String? {
    let pattern = "^\(NSRegularExpression.escapedPattern(for: name)) (\\S+)"
    let regex = try? NSRegularExpression(pattern: pattern)
    guard let match = regex?.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
          let range = Range(match.range(at: 1), in: subject)
    else { return nil }
    return String(subject[range])
}

// MARK: - Routing

/// Where a package's history lives (§21): the GitHub repo for core packages,
/// the tap's own git clone for tap packages, or nowhere (with the reason the
/// GUI shows verbatim).
public enum HistoryRoute: Equatable, Sendable {
    case github(repo: String, path: String)
    case tapGit(tapDirectory: String, file: String)
    case unsupported(reason: String)
}

public let coreFormulaRepo = "Homebrew/homebrew-core"
public let coreCaskRepo = "Homebrew/homebrew-cask"

/// Buckets from `CoreTap#new_formula_subdirectory` (read from the local
/// install 2026-10-30, placement verified via the contents API): names starting
/// with "lib" live in Formula/lib (libgit2, libpng, libyaml — liquidsoap does
/// NOT start with "lib" and stays in Formula/l). A `Formulae/` prefix 404s (§21).
public func coreFormulaDefinitionPath(name: String) -> String {
    let bucket = name.lowercased().hasPrefix("lib") ? "lib" : String(name.lowercased().prefix(1))
    return "Formula/\(bucket)/\(name).rb"
}

/// Buckets from `CoreCaskTap#new_cask_subdirectory` (read from the local
/// install 2026-10-30, layout verified via the contents API): tokens starting
/// with "font-" live nested at Casks/font/font-<next letter>/<token>.rb;
/// everything else buckets on its first character — a–z and digit directories
/// (0, 1, 3, 4, 5, 7, 8) both exist.
public func coreCaskDefinitionPath(token: String) -> String {
    let lower = token.lowercased()
    if lower.hasPrefix("font-"), lower.count > 5 {
        return "Casks/font/font-\(lower.dropFirst(5).prefix(1))/\(token).rb"
    }
    return "Casks/\(lower.prefix(1))/\(token).rb"
}

/// Does this route need the (lazily loaded) tap list to be decided? Core and
/// unknown-tap rows are decided from the item alone, like `brewPageURL`.
public func historyRouteNeedsTaps(for item: BrewItem) -> Bool {
    guard let tap = item.tap else { return false }
    switch tap.lowercased() {
    case "homebrew/core", "homebrew/cask": return false
    default: return true
    }
}

public func historyRoute(for item: BrewItem, taps: [TapInfo]) -> HistoryRoute {
    // Unknown tap (text-list fallback rows): same guess as the brew-page link —
    // the official repo for the item's kind. A wrong guess surfaces as an
    // empty commit list, not a wrong history.
    guard let tap = item.tap else {
        return item.kind == .formula
            ? .github(repo: coreFormulaRepo, path: coreFormulaDefinitionPath(name: item.name))
            : .github(repo: coreCaskRepo, path: coreCaskDefinitionPath(token: item.name))
    }
    switch tap.lowercased() {
    case "homebrew/core", "homebrew/cask":
        return item.kind == .cask
            ? .github(repo: coreCaskRepo, path: coreCaskDefinitionPath(token: item.name))
            : .github(repo: coreFormulaRepo, path: coreFormulaDefinitionPath(name: item.name))
    default:
        guard let info = taps.first(where: { $0.name.lowercased() == tap.lowercased() }) else {
            return .unsupported(reason: "Tap \(tap) is not in the tap list — open the Taps pane, then retry.")
        }
        // Virtual API-mode taps report installed: false and a phantom path (§21).
        guard info.installed, let directory = info.onDiskPath else {
            return .unsupported(reason: "Tap \(tap) is not cloned on disk (API mode) — no local git history.")
        }
        let files = item.kind == .formula ? info.formulaFiles : info.caskFiles
        let suffix = "/\(item.name).rb"
        guard let absolute = files.first(where: { $0.hasSuffix(suffix) }) else {
            return .unsupported(reason: "No definition file for \(item.name) in \(tap).")
        }
        // tap-info reports absolute paths; git wants them relative to the tap root.
        let file = absolute.hasPrefix(directory + "/")
            ? String(absolute.dropFirst(directory.count + 1)) : absolute
        return .tapGit(tapDirectory: directory, file: file)
    }
}

// MARK: - Decoders

/// GitHub REST commits-by-path JSON (compat §21): a top-level array of commit
/// objects. Unknown keys ignored, nulls tolerated, malformed entries skipped.
private struct GitHubCommit: Decodable {
    struct Commit: Decodable {
        struct Author: Decodable { let date: String? }
        let message: String?
        let author: Author?
    }
    let sha: String?
    let htmlUrl: String?
    let commit: Commit?

    enum CodingKeys: String, CodingKey { case sha, htmlUrl = "html_url", commit }
}

public func decodeGitHubCommits(_ data: Data, name: String) throws -> [VersionHistoryEntry] {
    guard let commits = try? JSONDecoder().decode([GitHubCommit].self, from: data) else {
        throw VersionHistoryError(message: "GitHub returned an unexpected response.")
    }
    return commits.enumerated().compactMap { index, commit in
        guard let message = commit.commit?.message, !message.isEmpty else { return nil }
        let subject = message.split(separator: "\n", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return VersionHistoryEntry(
            id: commit.sha ?? "commit-\(index)",
            subject: subject,
            date: parseTimestamp(commit.commit?.author?.date),
            versionBump: versionBump(in: subject, name: name),
            webURL: commit.htmlUrl.flatMap(URL.init(string:)))
    }
}

/// `git log --date=iso-strict --pretty=format:%H%x1f%ad%x1f%s` output
/// (verified live on umputun/apps 2026-10-30): one commit per line, fields
/// separated by unit-separator (0x1F).
public let gitFieldSeparator = "\u{1F}"

public func decodeTapGitLog(_ text: String, name: String) -> [VersionHistoryEntry] {
    text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        let fields = line.split(separator: Character(gitFieldSeparator), omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, let sha = fields.first, !sha.isEmpty else { return nil }
        let subject = fields[2]
        return VersionHistoryEntry(
            id: sha,
            subject: subject,
            date: parseTimestamp(fields[1]),
            versionBump: versionBump(in: subject, name: name),
            webURL: nil)
    }
}

/// GitHub ("2026-09-22T12:34:43Z") parses with .withInternetDateTime; git
/// iso-strict ("2026-10-30T01:13:44-05:00") gets a ZZZZZ fallback in case an
/// older git emits the offset without a colon. Anything else → dateless entry.
private func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: raw) { return date }
    let relaxed = DateFormatter()
    relaxed.locale = Locale(identifier: "en_US_POSIX")
    relaxed.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
    return relaxed.date(from: raw)
}

public struct VersionHistoryError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

// MARK: - Upstream release notes (best-effort, §21)

/// GitHub owner/repo derived from a homepage URL. Coverage is uneven — the GUI
/// treats "no match" as "no Release notes button", same fallback as the site.
public func upstreamGitHubRepo(homepage: String?) -> (owner: String, repo: String)? {
    guard let homepage, let components = URLComponents(string: homepage) else { return nil }
    guard let host = components.host?.lowercased(),
          host == "github.com" || host == "www.github.com" else { return nil }
    let path = components.path.split(separator: "/").map(String.init)
    guard path.count >= 2 else { return nil }
    let owner = path[0]
    var repo = path[1]
    if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
    guard !owner.isEmpty, !repo.isEmpty else { return nil }
    return (owner, repo)
}

public func releaseNotesURL(for item: BrewItem) -> URL? {
    guard let repo = upstreamGitHubRepo(homepage: item.homepage) else { return nil }
    return URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/releases")
}

// MARK: - Fetching

/// Token-mode GitHub REST seam (tests fake it; LiveGitHubJSON does URLSession).
public protocol GitHubJSONFetching: Sendable {
    func gitHubJSON(url: URL, token: String?) async throws -> Data
}

public struct LiveGitHubJSON: GitHubJSONFetching {
    public init() {}

    public func gitHubJSON(url: URL, token: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("brewery", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VersionHistoryError(message: "Unexpected response from GitHub.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VersionHistoryError(message: Self.gitHubFailureMessage(status: http.statusCode, body: data))
        }
        return data
    }

    /// GitHub's own `message` field names the problem (rate limit, bad token);
    /// surface it with the status code, truncated like the other brew errors.
    private static func gitHubFailureMessage(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = json?["message"] as? String
        var text = message.flatMap { $0.isEmpty ? nil : "GitHub: \($0)" } ?? "GitHub returned HTTP \(status)."
        if status == 401 { text += " — the token in Settings → Changelogs is expired or revoked." }
        if status == 403, text.contains("rate limit") { text += " — try again later." }
        return text.count > 300 ? "…" + text.suffix(300) : text
    }
}

public struct VersionHistoryFetcher: Sendable {
    public struct Access: Equatable, Sendable {
        public var source: ChangelogSource = .off
        public var token: String = ""
        public init() {}
    }

    /// Timeline length per package: 30 commits is the GUI's page; unauthenticated
    /// GitHub would make even this hurt (§21), but the feature is token/gh-only.
    public static let perPage = 30

    public var access: Access
    public let gitURL: URL?
    public let ghURL: URL?
    public let exec: ExecRunning
    public let github: GitHubJSONFetching

    public init(access: Access, gitURL: URL?, ghURL: URL?,
                exec: ExecRunning, github: GitHubJSONFetching) {
        self.access = access
        self.gitURL = gitURL
        self.ghURL = ghURL
        self.exec = exec
        self.github = github
    }

    /// gh needs `-X GET` explicitly: with -f params gh defaults to POST.
    /// Layout verified live 2026-10-30 against Formula/w/wget.rb.
    public static func ghArguments(repo: String, path: String) -> [String] {
        ["api", "repos/\(repo)/commits", "-X", "GET",
         "-f", "path=\(path)", "-f", "per_page=\(perPage)"]
    }

    public static func commitsURL(repo: String, path: String) -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/\(repo)/commits")!
        components.queryItems = [URLQueryItem(name: "path", value: path),
                                 URLQueryItem(name: "per_page", value: String(perPage))]
        return components.url!
    }

    public func fetch(route: HistoryRoute, name: String) async throws -> [VersionHistoryEntry] {
        switch route {
        case .github(let repo, let path):
            let data: Data
            switch access.source {
            case .off:
                throw VersionHistoryError(message: "Version history is off — pick a GitHub source in Settings → Changelogs.")
            case .token:
                let token = access.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else {
                    throw VersionHistoryError(message: "No GitHub token set — add one in Settings → Changelogs.")
                }
                data = try await github.gitHubJSON(url: Self.commitsURL(repo: repo, path: path), token: token)
            case .ghCLI:
                guard let gh = ghURL else {
                    throw VersionHistoryError(message: "gh not found — install it with `brew install gh`.")
                }
                let result = try await exec.run(gh, Self.ghArguments(repo: repo, path: path))
                guard result.exitCode == 0 else {
                    throw VersionHistoryError(message: Self.commandFailure(result, fallback: "gh api failed (exit \(result.exitCode))."))
                }
                data = result.stdout
            }
            return try decodeGitHubCommits(data, name: name)

        case .tapGit(let directory, let file):
            guard let git = gitURL else {
                throw VersionHistoryError(message: "git not found — run `xcode-select --install` for the Command Line Tools.")
            }
            let result = try await exec.run(git, ["-C", directory, "log",
                                                  "--max-count=\(Self.perPage)", "--date=iso-strict",
                                                  "--pretty=format:%H\(gitFieldSeparator)%ad\(gitFieldSeparator)%s",
                                                  "--", file])
            guard result.exitCode == 0 else {
                throw VersionHistoryError(message: Self.commandFailure(result, fallback: "git log failed (exit \(result.exitCode))."))
            }
            return decodeTapGitLog(String(decoding: result.stdout, as: UTF8.self), name: name)

        case .unsupported(let reason):
            throw VersionHistoryError(message: reason)
        }
    }

    private static func commandFailure(_ result: BrewResult, fallback: String) -> String {
        let text = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var message = firstLine.map { String($0) } ?? fallback
        if message.count > 300 { message = "…" + message.suffix(300) }
        return message
    }
}
