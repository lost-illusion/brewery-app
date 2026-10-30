import Foundation

/// brew's tap name is `user/repo`; both halves are needed to build the GitHub URL.
private func splitTapName(_ name: String) -> (user: String?, repo: String?) {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return (nil, nil) }
    return (String(parts[0]), String(parts[1]))
}

/// One tap as reported by `brew tap-info --installed --json` (compat §7).
/// Output is a bare JSON array. Official API-mode taps report only the identity
/// block; a tap cloned on disk adds the git block (`remote`, `HEAD`, …).
/// Missing keys default, unknown keys are ignored.
public struct TapInfo: Identifiable, Hashable, Codable {
    public let id: String              // brew's tap name, e.g. "umputun/apps"
    public let user: String?
    public let repo: String?
    public let onDiskPath: String?     // JSON "path"
    public let installed: Bool         // false → API mode: not cloned on disk
    public let official: Bool
    public let trusted: Bool?          // omitted by some builds → unknown
    public let formulaNames: [String]  // everything the tap offers, not just installed
    public let caskTokens: [String]
    /// On-disk definition paths — arrays of file names, not counts, and present
    /// only for cloned taps.
    public let formulaFiles: [String]
    public let caskFiles: [String]
    public let commandFiles: [String]
    public let remote: String?         // cloned taps only
    public let customRemote: Bool
    public let isPrivate: Bool
    public let head: String?
    public let lastCommitText: String? // brew's own relative wording, e.g. "2 days ago"
    public let branch: String?

    public var name: String { id }
    public var isExternal: Bool { !official }
    public var availableCount: Int { formulaNames.count + caskTokens.count }

    /// The GitHub URL `brew tap <user>/<repo>` would clone (§7 naming rule).
    public var resolvedRemote: String? {
        guard let user, let repo else { return nil }
        return "https://github.com/\(user)/homebrew-\(repo)"
    }

    /// Placeholder row for the no-jq fallback (`brew tap` prints names only).
    public init(name: String) {
        id = name
        let parts = splitTapName(name)
        user = parts.user
        repo = parts.repo
        onDiskPath = nil
        installed = true
        official = name.lowercased().hasPrefix("homebrew/")
        trusted = nil
        formulaNames = []
        caskTokens = []
        formulaFiles = []
        caskFiles = []
        commandFiles = []
        remote = nil
        customRemote = false
        isPrivate = false
        head = nil
        lastCommitText = nil
        branch = nil
    }

    enum CodingKeys: String, CodingKey {
        case id = "name", user, repo
        case onDiskPath = "path"
        case installed, official, trusted
        case formulaNames = "formula_names", caskTokens = "cask_tokens"
        case formulaFiles = "formula_files", caskFiles = "cask_files", commandFiles = "command_files"
        case remote, customRemote = "custom_remote"
        case isPrivate = "private"
        case head = "HEAD" // brew spells this key in caps
        case lastCommitText = "last_commit"
        case branch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Some builds report only the name; the name itself is user/repo.
        let parts = splitTapName(id)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? parts.user
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? parts.repo
        onDiskPath = try c.decodeIfPresent(String.self, forKey: .onDiskPath)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted)
        formulaNames = try c.decodeIfPresent([String].self, forKey: .formulaNames) ?? []
        caskTokens = try c.decodeIfPresent([String].self, forKey: .caskTokens) ?? []
        formulaFiles = try c.decodeIfPresent([String].self, forKey: .formulaFiles) ?? []
        caskFiles = try c.decodeIfPresent([String].self, forKey: .caskFiles) ?? []
        commandFiles = try c.decodeIfPresent([String].self, forKey: .commandFiles) ?? []
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
        customRemote = try c.decodeIfPresent(Bool.self, forKey: .customRemote) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        head = try c.decodeIfPresent(String.self, forKey: .head)
        lastCommitText = try c.decodeIfPresent(String.self, forKey: .lastCommitText)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
    }

    /// `tap-info` emits a top-level array, not an object.
    public static func decode(_ data: Data) throws -> [TapInfo] {
        try JSONDecoder().decode([TapInfo].self, from: data)
    }
}

/// External taps first (they are the ones the GUI manages), then on-disk, then by name.
public func sortedTapsForDisplay(_ taps: [TapInfo]) -> [TapInfo] {
    taps.sorted { a, b in
        if a.isExternal != b.isExternal { return a.isExternal }
        if a.installed != b.installed { return a.installed }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// Fallback parser for `brew tap` (no jq → the app never asks brew for JSON).
/// One `user/repo` per line; any trailing annotation is dropped.
public func parseTapNames(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let token = line.split(separator: " ").first else { return nil }
        let name = String(token)
        return name.contains("/") ? name : nil
    }
}

public enum TapNameProblem: Error, Equatable {
    case empty
    case needsUserAndRepo
    case emptySegment
    case illegalCharacter(Character)

    public var message: String {
        switch self {
        case .empty: "enter a tap name"
        case .needsUserAndRepo: "tap names look like user/repo"
        case .emptySegment: "both user and repo are required"
        case .illegalCharacter(let c): "“\(c)” is not allowed — letters, digits, dot, dash, underscore"
        }
    }
}

/// Validates the `user/repo` form before any mutating `brew tap` runs.
public func parseTapName(_ raw: String) -> Result<(user: String, repo: String), TapNameProblem> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .failure(.empty) }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    if parts.count != 2 { return .failure(.needsUserAndRepo) }
    let user = String(parts[0]), repo = String(parts[1])
    if user.isEmpty || repo.isEmpty { return .failure(.emptySegment) }
    for char in user + repo {
        if char.isLetter || char.isNumber { continue }
        if char == "." || char == "-" || char == "_" { continue }
        return .failure(.illegalCharacter(char))
    }
    return .success((user, repo))
}

/// brew's two-argument form clones from any git transport (§7), so a custom
/// remote is checked for shape only — brew/git decide whether it works.
public func validateTapRemote(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) {
        return "a remote URL cannot contain spaces"
    }
    let allowedSchemes = ["https", "http", "git", "ssh", "ftps", "ftp", "rsync", "file"]
    guard let scheme = URL(string: trimmed)?.scheme?.lowercased(),
          allowedSchemes.contains(scheme)
    else { return "remote must start with https://, git://, ssh:// …" }
    return trimmed.contains("//") ? nil : "remote must name a repository"
}

/// `tap-info` reports a cloned tap's contents fully qualified
/// (`umputun/apps/cronn`); the GUI lists them bare, inside the tap's own pane.
func bareName(_ tap: TapInfo, _ reported: String) -> String {
    let prefix = "\(tap.name)/"
    return reported.hasPrefix(prefix) ? String(reported.dropFirst(prefix.count)) : reported
}

/// What a tap offers, cross-referenced against the installed inventory.
public struct TapContents: Equatable {
    public struct Entry: Identifiable, Equatable {
        public var id: String { "\(kind.rawValue):\(name)" }
        public let name: String
        public let kind: BrewItem.Kind
        public let installed: BrewItem?
    }

    public let entries: [Entry]
    public let installedCount: Int

    public func filtered(_ query: String?) -> [Entry] {
        guard let query, !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

/// Names come from the tap's own lists; a row counts as installed when it is
/// the same kind under the same tap. Rows with an unknown tap (untrusted taps
/// are skipped by `brew info` — §43) are matched on name instead, so their
/// installed state is not silently lost.
public func tapContents(of tap: TapInfo, inventory: [BrewItem]) -> TapContents {
    var qualified: [String: BrewItem] = [:]
    var bare: [String: [BrewItem]] = [:]
    for item in inventory {
        if let tapName = item.tap { qualified["\(tapName)/\(item.name)"] = item }
        bare[item.name, default: []].append(item)
    }

    func installed(_ reported: String, _ kind: BrewItem.Kind) -> BrewItem? {
        // A cloned tap reports qualified names, which match an inventory row's
        // `<tap>/<name>` key directly; an API tap reports bare names.
        if let exact = qualified[reported], exact.kind == kind { return exact }
        // Casks key on the bare token (§47); list-only rows carry no tap at all.
        return bare[bareName(tap, reported)]?.first {
            $0.kind == kind && ($0.tap == nil || $0.tap == tap.name)
        }
    }

    var entries: [TapContents.Entry] = []
    entries.reserveCapacity(tap.formulaNames.count + tap.caskTokens.count)
    for reported in tap.formulaNames {
        entries.append(.init(name: bareName(tap, reported), kind: .formula, installed: installed(reported, .formula)))
    }
    for reported in tap.caskTokens {
        entries.append(.init(name: bareName(tap, reported), kind: .cask, installed: installed(reported, .cask)))
    }
    return TapContents(entries: entries, installedCount: entries.filter { $0.installed != nil }.count)
}
