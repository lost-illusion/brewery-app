import Foundation
import Testing
@testable import BreweryCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("brewery-t2-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makeScript(dir: URL, name: String, content: String, executable: Bool) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return url
}

@Test func discoverBrew_findsFirstExecutableAndPrefersOverride() throws {
    let dirA = try makeTempDir("A")
    let dirB = try makeTempDir("B")
    let brewA = try makeScript(dir: dirA, name: "brew", content: "#!/bin/sh\nexit 0\n", executable: true)
    let brewB = try makeScript(dir: dirB, name: "brew", content: "#!/bin/sh\nexit 0\n", executable: true)

    #expect(discoverBrew(searchPaths: [brewA.path, brewB.path], pathOverride: nil)?.path == brewA.path)
    #expect(discoverBrew(searchPaths: [brewA.path, brewB.path], pathOverride: brewB.path)?.path == brewB.path)
    #expect(discoverBrew(searchPaths: ["/nonexistent-a/brew", "/nonexistent-b/brew"], pathOverride: nil) == nil)
}

@Test func discoverBrew_rejectsNonExecutable() throws {
    let dir = try makeTempDir("C")
    let notExecutable = try makeScript(dir: dir, name: "brew", content: "#!/bin/sh\nexit 0\n", executable: false)
    let executable = try makeScript(dir: dir, name: "real-brew", content: "#!/bin/sh\nexit 0\n", executable: true)
    #expect(discoverBrew(searchPaths: [notExecutable.path, executable.path], pathOverride: nil)?.path == executable.path)
}

@Test func run_passesArgsAndCapturesStreams() async throws {
    let dir = try makeTempDir("D")
    let script = try makeScript(
        dir: dir, name: "fake-brew.sh",
        content: "#!/bin/sh\necho \"args: $*\"\necho errline >&2\nexit 0\n", executable: true)
    let result = try await BrewRunner(brewURL: script).run(["list", "--json", "--versions"])
    #expect(String(data: result.stdout, encoding: .utf8) == "args: list --json --versions\n")
    #expect(String(data: result.stderr, encoding: .utf8) == "errline\n")
    #expect(result.exitCode == 0)
}

@Test func run_exitCodeAndFailure() async throws {
    let dir = try makeTempDir("E")
    let script = try makeScript(
        dir: dir, name: "fake-brew.sh",
        content: "#!/bin/sh\necho boom >&2\nexit 1\n", executable: true)
    let result = try await BrewRunner(brewURL: script).run(["info"])
    #expect(result.exitCode == 1)
    #expect(String(data: result.stderr, encoding: .utf8) == "boom\n")
}

@Test func run_envHygiene() async throws {
    let dir = try makeTempDir("F")
    let script = try makeScript(
        dir: dir, name: "fake-brew.sh",
        content: "#!/bin/sh\necho \"DEV=${HOMEBREW_DEVELOPER-UNSET} AU=$HOMEBREW_NO_AUTO_UPDATE FORCE=${HOMEBREW_FORCE_API_AUTO_UPDATE-UNSET}\"\n",
        executable: true)
    // extraEnv deliberately tries to re-inject stripped vars; the fixed filter must win.
    // FORCE_API_AUTO_UPDATE overrides NO_AUTO_UPDATE for API data in brew itself, so it
    // must never reach the child (design §Scheduling & Homebrew safety).
    let runner = BrewRunner(brewURL: script, extraEnv: ["HOMEBREW_DEVELOPER": "1", "HOMEBREW_FORCE_API_AUTO_UPDATE": "1"])
    let result = try await runner.run([])
    #expect(String(data: result.stdout, encoding: .utf8) == "DEV=UNSET AU=1 FORCE=UNSET\n")
}
