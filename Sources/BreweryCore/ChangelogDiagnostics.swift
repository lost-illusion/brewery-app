import Foundation

/// How a future changelog feature reaches GitHub (§21):
/// no changelog, a user-supplied REST token, or shelling out to an already
/// signed-in `gh` (its own auth, no token in the app).
public enum ChangelogSource: String, CaseIterable, Identifiable {
    case off, token, ghCLI

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: "Off"
        case .token: "GitHub token"
        case .ghCLI: "Local gh CLI"
        }
    }
}

/// Result of one settings-pane diagnostic. `detail` is the success line
/// (git version, gh login, token owner).
public enum ProbeOutcome: Equatable {
    case ok(detail: String)
    case failed(message: String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// Runs an arbitrary executable. Separate from BrewRunner (which is locked to
/// the brew binary) — this is the seam tests fake to probe git/gh.
public protocol ExecRunning: Sendable {
    func run(_ executable: URL, _ args: [String]) async throws -> BrewResult
}

public struct ProcessExecRunner: ExecRunning {
    public init() {}

    public func run(_ executable: URL, _ args: [String]) async throws -> BrewResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // A probe must never pop a credential prompt on the user's screen.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        process.environment = env

        nonisolated(unsafe) let outPipe = Pipe()
        nonisolated(unsafe) let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let stdoutTask = Task { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }
        await process.waitUntilExit()
        return BrewResult(exitCode: process.terminationStatus,
                          stdout: await stdoutTask.value,
                          stderr: await stderrTask.value)
    }
}

/// Token validation without URLSession baked in, so tests never hit the network.
public protocol GitHubTokenChecking: Sendable {
    func check(token: String) async -> ProbeOutcome
}

/// Real checker: GET /user with the bearer token — a cheap authenticated call
/// that proves the token is live without consuming search rate limits.
public struct GitHubAPITokenChecker: GitHubTokenChecking {
    public init() {}

    public func check(token: String) async -> ProbeOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(message: "No token entered.") }

        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("brewery", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "Unexpected response from GitHub.")
            }
            switch http.statusCode {
            case 200:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let login = json?["login"] as? String {
                    return .ok(detail: "Authenticated as \(login)")
                }
                return .ok(detail: "Token accepted.")
            case 401: return .failed(message: "Token rejected (401) — expired or revoked?")
            case 403: return .failed(message: "Token rejected (403) — check its scopes.")
            default: return .failed(message: "GitHub returned HTTP \(http.statusCode).")
            }
        } catch {
            return .failed(message: "Network error: \(error.localizedDescription)")
        }
    }
}

/// The three checks the Changelogs settings pane runs: local git, local gh,
/// GitHub token. Discovery first, then one command each — exit code is the verdict.
/// Discovery is injectable so tests never depend on what is installed on the test machine.
public struct ChangelogDiagnostics: Sendable {
    // /usr/bin/git is Apple's shim: present even without the Command Line
    // Tools, where running it fails — the stderr check below reports that case.
    public static let defaultGitSearchPaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    public static let defaultGhSearchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
                                              NSHomeDirectory() + "/.local/bin/gh"]

    private static let maxReportedErrorLength = 200

    private let exec: ExecRunning
    private let tokenChecker: GitHubTokenChecking
    private let gitSearchPaths: [String]
    private let ghSearchPaths: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(exec: ExecRunning, tokenChecker: GitHubTokenChecking,
                gitSearchPaths: [String] = ChangelogDiagnostics.defaultGitSearchPaths,
                ghSearchPaths: [String] = ChangelogDiagnostics.defaultGhSearchPaths,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.exec = exec
        self.tokenChecker = tokenChecker
        self.gitSearchPaths = gitSearchPaths
        self.ghSearchPaths = ghSearchPaths
        self.isExecutable = isExecutable
    }

    private func discover(searchPaths: [String]) -> URL? {
        searchPaths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    public func probeGit() async -> ProbeOutcome {
        guard let git = discover(searchPaths: gitSearchPaths) else {
            return .failed(message: "git not found in \(gitSearchPaths.joined(separator: ", ")).")
        }
        do {
            let result = try await exec.run(git, ["--version"])
            if result.exitCode == 0 {
                let version = trimmedText(result.stdout)
                return .ok(detail: version.isEmpty ? "git available" : version)
            }
            let stderr = trimmedText(result.stderr)
            if stderr.contains("Command Line Tools") {
                return .failed(message: "git needs the Xcode Command Line Tools — run `xcode-select --install`.")
            }
            return .failed(message: Self.report(of: stderr.isEmpty ? trimmedText(result.stdout) : stderr,
                                                fallback: "git --version failed (exit \(result.exitCode))."))
        } catch {
            return .failed(message: "Could not run git: \(error.localizedDescription)")
        }
    }

    public func probeGh() async -> ProbeOutcome {
        guard let gh = discover(searchPaths: ghSearchPaths) else {
            return .failed(message: "gh not found — install it with `brew install gh`.")
        }
        do {
            // gh auth status prints its report on stderr, not stdout.
            let result = try await exec.run(gh, ["auth", "status"])
            let report = trimmedText(result.stdout) + "\n" + trimmedText(result.stderr)
            if result.exitCode == 0 {
                if let line = report.split(separator: "\n").first(where: { $0.contains("github.com") }) {
                    return .ok(detail: "Signed in — \(line.trimmingCharacters(in: .whitespaces))")
                }
                return .ok(detail: "gh signed in.")
            }
            return .failed(message: Self.ghFailureReport(of: report,
                                                          fallback: "gh is not signed in — run `gh auth login`."))
        } catch {
            return .failed(message: "Could not run gh: \(error.localizedDescription)")
        }
    }

    public func probeToken(_ token: String) async -> ProbeOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(message: "No token entered.") }
        return await tokenChecker.check(token: trimmed)
    }

    private static func report(of text: String, fallback: String) -> String {
        let firstMeaningfulLine = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line = firstMeaningfulLine else { return fallback }
        return truncate(line)
    }

    /// `gh auth status` starts with a "github.com" header even when the check
    /// failed, so the first line is not the error — hunt for the failing line.
    private static func ghFailureReport(of text: String, fallback: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { !$0.isEmpty && ($0.contains("Failed") || $0.contains("error") || $0.hasPrefix("X ")) }) {
            return truncate(line)
        }
        return report(of: text, fallback: fallback)
    }

    private static func truncate(_ line: String) -> String {
        line.count > maxReportedErrorLength ? String(line.prefix(maxReportedErrorLength)) + "…" : line
    }

    private func trimmedText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
