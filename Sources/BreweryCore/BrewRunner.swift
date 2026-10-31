import Foundation

public struct BrewResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol CommandRunning: Sendable {
    func run(_ args: [String]) async throws -> BrewResult
}

public struct BrewRunner: CommandRunning {
    private static let fixedEnv: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_COLOR": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
    ]
    // Stripped after every merge so nothing — parent env or extraEnv — can re-inject them (§13).
    // FORCE_API_AUTO_UPDATE overrides NO_AUTO_UPDATE for API data (docs Manpage), so a user
    // who set it would silently re-arm the auto-update our fixedEnv exists to prevent (design
    // §Scheduling & Homebrew safety).
    private static let strippedEnvKeys: [String] = ["HOMEBREW_DEVELOPER", "HOMEBREW_VERBOSE", "HOMEBREW_DEBUG", "HOMEBREW_FORCE_API_AUTO_UPDATE"]

    private let brewURL: URL
    private let extraEnv: [String: String]

    public init(brewURL: URL, extraEnv: [String: String] = [:]) {
        self.brewURL = brewURL
        self.extraEnv = extraEnv
    }

    public func run(_ args: [String]) async throws -> BrewResult {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in Self.strippedEnvKeys { env.removeValue(forKey: key) }
        env.merge(Self.fixedEnv) { _, new in new }
        env.merge(extraEnv) { _, new in new }
        for key in Self.strippedEnvKeys { env.removeValue(forKey: key) }
        process.environment = env

        nonisolated(unsafe) let outPipe = Pipe()
        nonisolated(unsafe) let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Drain concurrently with exit: brew info output exceeds the pipe buffer.
        let stdoutTask = Task { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }
        await process.waitUntilExit()
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        return BrewResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
