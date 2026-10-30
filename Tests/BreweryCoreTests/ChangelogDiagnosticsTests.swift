import Foundation
import Testing
@testable import BreweryCore

// MARK: - Fakes

/// Scripted by "path args" so a probe can be asserted on which executable it chose.
private final class ScriptedExec: ExecRunning, @unchecked Sendable {
    private let results: [String: BrewResult]
    private(set) var calls: [String] = []
    init(results: [String: BrewResult]) { self.results = results }

    func run(_ executable: URL, _ args: [String]) async throws -> BrewResult {
        calls.append(executable.path + " " + args.joined(separator: " "))
        await Task.yield()
        let key = executable.path + " " + args.joined(separator: " ")
        guard let result = results[key] else {
            return BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted: \(key)".utf8))
        }
        return result
    }
}

private final class FakeTokenChecker: GitHubTokenChecking, @unchecked Sendable {
    private let outcome: ProbeOutcome
    private(set) var sawToken: String?
    init(outcome: ProbeOutcome) { self.outcome = outcome }
    func check(token: String) async -> ProbeOutcome {
        sawToken = token
        return outcome
    }
}

private func ok(_ text: String) -> BrewResult { BrewResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data()) }
private func okErr(_ text: String) -> BrewResult { BrewResult(exitCode: 0, stdout: Data(), stderr: Data(text.utf8)) }
private func fail(_ text: String) -> BrewResult { BrewResult(exitCode: 1, stdout: Data(), stderr: Data(text.utf8)) }

private func makeDiagnostics(gitResults: [String: BrewResult] = [:],
                             ghResults: [String: BrewResult] = [:],
                             tokenOutcome: ProbeOutcome = .ok(detail: "stub"),
                             gitFound: Bool = true,
                             ghFound: Bool = true) -> (ChangelogDiagnostics, ScriptedExec) {
    var results: [String: BrewResult] = [:]
    results.merge(gitResults) { _, new in new }
    results.merge(ghResults) { _, new in new }
    let exec = ScriptedExec(results: results)
    let diagnostics = ChangelogDiagnostics(
        exec: exec,
        tokenChecker: FakeTokenChecker(outcome: tokenOutcome),
        gitSearchPaths: ["/fake/git"],
        ghSearchPaths: ["/fake/gh"],
        isExecutable: { path in path == "/fake/git" ? gitFound : ghFound }
    )
    return (diagnostics, exec)
}

// MARK: - ChangelogSource

@Test func changelogSource_rawRoundTripForAppStorage() {
    for source in ChangelogSource.allCases {
        #expect(ChangelogSource(rawValue: source.rawValue) == source)
    }
    #expect(ChangelogSource(rawValue: "garbage") == nil) // @AppStorage falls back to the default
    #expect(ChangelogSource.allCases.map(\.rawValue) == ["off", "token", "ghCLI"])
    #expect(ChangelogSource.ghCLI.label == "Local gh CLI")
}

// MARK: - git probe

@Test func probeGit_reportsVersionOnSuccess() async {
    let (diagnostics, exec) = makeDiagnostics(gitResults: ["/fake/git --version": ok("git version 2.50.1\n")])
    let outcome = await diagnostics.probeGit()
    #expect(outcome == .ok(detail: "git version 2.50.1"))
    #expect(exec.calls == ["/fake/git --version"])
}

@Test func probeGit_namesMissingGit() async {
    let (diagnostics, exec) = makeDiagnostics(gitFound: false)
    let outcome = await diagnostics.probeGit()
    #expect(outcome == .failed(message: "git not found in /fake/git."))
    #expect(exec.calls.isEmpty) // never runs a command it could not locate
}

@Test func probeGit_translatesCLTShimFailureIntoTheFix() async {
    // /usr/bin/git exists even without the Command Line Tools; running it fails with this wording.
    let (diagnostics, _) = makeDiagnostics(gitResults: [
        "/fake/git --version": fail("xcode-select: error: tool 'git' requires Xcode Command Line Tools but did not find a valid path"),
    ])
    let outcome = await diagnostics.probeGit()
    #expect(outcome == .failed(message: "git needs the Xcode Command Line Tools — run `xcode-select --install`."))
}

@Test func probeGit_surfacesOtherFailuresFirstLineOnly() async {
    let (diagnostics, _) = makeDiagnostics(gitResults: [
        "/fake/git --version": fail("\nweird noise\nsecond line that should not appear\n"),
    ])
    let outcome = await diagnostics.probeGit()
    #expect(outcome == .failed(message: "weird noise"))
}

// MARK: - gh probe

@Test func probeGh_readsSigninFromStderrBecauseThatIsWhereGhWrites() async {
    // real `gh auth status` layout (verified 2026-10-30 on this machine)
    let (diagnostics, exec) = makeDiagnostics(ghResults: [
        "/fake/gh auth status": okErr("""
        github.com
          ✓ Logged in to github.com account illusion (keyring)
          - Active account: true
        """),
    ])
    let outcome = await diagnostics.probeGh()
    #expect(outcome == .ok(detail: "Signed in — github.com"))
    #expect(exec.calls == ["/fake/gh auth status"])
}

@Test func probeGh_namesMissingGh() async {
    let (diagnostics, exec) = makeDiagnostics(ghFound: false)
    let outcome = await diagnostics.probeGh()
    #expect(outcome == .failed(message: "gh not found — install it with `brew install gh`."))
    #expect(exec.calls.isEmpty)
}

@Test func probeGh_reportsNotSignedIn() async {
    let (diagnostics, _) = makeDiagnostics(ghResults: [
        "/fake/gh auth status": fail("github.com\n  X Failed to log in to github.com account ghost"),
    ])
    let outcome = await diagnostics.probeGh()
    if case .failed(let message) = outcome {
        #expect(message.contains("Failed to log in")) // gh's own wording, verbatim, first line
    } else {
        Issue.record("expected .failed, got \(outcome)")
    }
}

// MARK: - token probe

@Test func probeToken_refusesEmptyWithoutCallingTheChecker() async {
    let (diagnostics, exec) = makeDiagnostics()
    let outcome = await diagnostics.probeToken("   \n")
    #expect(outcome == .failed(message: "No token entered."))
    #expect(exec.calls.isEmpty)
}

@Test func probeToken_passesTrimmedTokenThrough() async {
    let checker = FakeTokenChecker(outcome: .ok(detail: "Authenticated as illusion"))
    let diagnostics = ChangelogDiagnostics(exec: ScriptedExec(results: [:]),
                                           tokenChecker: checker,
                                           gitSearchPaths: [], ghSearchPaths: [],
                                           isExecutable: { _ in false })
    let outcome = await diagnostics.probeToken("  ghp_secret  ")
    #expect(outcome == .ok(detail: "Authenticated as illusion"))
    #expect(checker.sawToken == "ghp_secret") // trimmed before it reaches the network layer
}

// MARK: - real runner (no fake): proves the Process plumbing itself

@Test func processExecRunner_runsRealEcho() async throws {
    let result = try await ProcessExecRunner().run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("hello"))
}
