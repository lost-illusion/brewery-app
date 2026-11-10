import Foundation

public struct BrewResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol CommandRunning: Sendable {
    func run(_ args: [String]) async throws -> BrewResult
    /// Streaming + cancellable variant (design 2026-11-02 phase 2). Declared as a
    /// requirement so conforming types' overrides dispatch; the extension in
    /// Streaming.swift gives a buffered default, so existing one-shot fakes keep
    /// working without implementing it.
    func runStreaming(_ args: [String], onLine: @escaping @Sendable (String) -> Void,
                      cancellation: BrewCancellationToken) async throws -> BrewResult
}

/// Cross-thread "the process has exited" flag for runStreaming's read loops.
final class ProcessExitedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    var isSet: Bool { lock.withLock { exited } }
    func set() { lock.withLock { exited = true } }
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

    private func makeProcess(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in Self.strippedEnvKeys { env.removeValue(forKey: key) }
        env.merge(Self.fixedEnv) { _, new in new }
        env.merge(extraEnv) { _, new in new }
        for key in Self.strippedEnvKeys { env.removeValue(forKey: key) }
        process.environment = env
        return process
    }

    public func run(_ args: [String]) async throws -> BrewResult {
        let process = makeProcess(args)

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

    /// Line-streaming variant for the long mutations (install/upgrade/tap/switch,
    /// design 2026-11-02 phase 2): one poll-driven task drains both pipes, so
    /// `onLine` fires while brew is still running, and `cancellation` interrupts
    /// the process mid-run. Full stdout/stderr are still collected for the
    /// failure-message path, so the BrewResult contract is identical to `run`.
    public func runStreaming(_ args: [String], onLine: @escaping @Sendable (String) -> Void,
                             cancellation: BrewCancellationToken) async throws -> BrewResult {
        let process = makeProcess(args)

        nonisolated(unsafe) let outPipe = Pipe()
        nonisolated(unsafe) let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // One loop drains both pipes with poll() on dup'd fds (dup'd so the loop owns
        // fds Foundation will not yank out from under it; O_NONBLOCK'd so a drain can
        // run to EAGAIN instead of hanging), delivering lines as brew writes them.
        // It runs on the global dispatch queue on purpose: the blocking poll windows
        // must not occupy a cooperative-pool thread — for the whole lifetime of a
        // brew run that starves every other Task in the app (measured 2026-11-10:
        // under a full test suite the cancel watchdog was starved 10 s).
        //
        // Within a poll window stdout is drained before stderr: two independent loops
        // raced on cross-stream order (flaked 2026-11-10), and one loop gives a
        // deterministic order that also matches how brew writes the two streams.
        // Per-pipe splitters keep partial lines until their terminator arrives.
        //
        // POLLIN is checked before POLLHUP because macOS reports both together when a
        // writer closes with bytes still unread (measured): checking HUP first discards
        // the final chunk — that is how a cancelled child's "got-int" line went missing.
        //
        // The loop ends on *process exit*, not on EOF — the difference matters for a
        // cancelled brew (measured 2026-11-10): brew's INT trap exits ruby while the
        // grandchildren it spawned (git, curl; in the test, a backgrounded `sleep`)
        // keep running with inherited copies of the pipe's write end, so EOF can lag
        // the exit by the grandchild's whole lifetime. AvailableData/readDataToEndOfFile
        // hangs in that window; after the exit flag, two silent 120 ms windows close
        // the capture — capped at 2 s past exit even if a grandchild streams forever,
        // because brew's own words are already in.
        //
        // An earlier theory — a child inheriting the spawning thread's blocked SIGINT
        // mask — was retired the same day: Foundation's spawn delivered SIGINT to the
        // child within ~50 ms even with the calling thread's (and even main's) mask
        // blocked, so no mask juggling belongs here.
        let processExited = ProcessExitedFlag()
        // The Task only suspends on the continuation (pool-free); the blocking loop
        // below runs on the global queue. Started before spawn so no early output is
        // missed, awaited after waitUntilExit.
        let readTask = Task { () -> (stdout: Data, stderr: Data) in
            await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outFD = dup(outPipe.fileHandleForReading.fileDescriptor)
                let errFD = dup(errPipe.fileHandleForReading.fileDescriptor)
                fcntl(outFD, F_SETFL, O_NONBLOCK)
                fcntl(errFD, F_SETFL, O_NONBLOCK)
                var outSplitter = BrewLineSplitter()
                var errSplitter = BrewLineSplitter()
                var outData = Data()
                var errData = Data()
                var outOpen = true
                var errOpen = true
                var quietWindows = 0
                var drainDeadline: Date?

                // Reads until the fd is momentarily empty (still open), or until EOF
                // / fault (returns false: close it). O_NONBLOCK: EAGAIN = drained.
                func drain(_ fd: Int32, _ splitter: inout BrewLineSplitter, _ collected: inout Data) -> Bool {
                    while true {
                        var buffer = [UInt8](repeating: 0, count: 16_384)
                        let count = read(fd, &buffer, buffer.count)
                        if count > 0 {
                            let chunk = Data(bytes: buffer, count: count)
                            collected.append(chunk)
                            for line in splitter.feed(chunk) { onLine(line) }
                            continue
                        }
                        if count == 0 { return false } // EOF: every writer closed the pipe
                        return errno == EAGAIN || errno == EINTR
                    }
                }

                while outOpen || errOpen {
                    // Once the process is gone, bound the capture to 2 more seconds even
                    // if a grandchild streams forever: brew's own words are already in.
                    if processExited.isSet {
                        if drainDeadline == nil { drainDeadline = Date().addingTimeInterval(2) }
                        else if Date() >= drainDeadline! { break }
                    }
                    var descriptors = [
                        pollfd(fd: outOpen ? outFD : -1, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: errOpen ? errFD : -1, events: Int16(POLLIN), revents: 0),
                    ]
                    let ready = poll(&descriptors, 2, 120)
                    if ready > 0 {
                        var sawData = false
                        if outOpen {
                            if descriptors[0].revents & Int16(POLLIN) != 0 {
                                if drain(outFD, &outSplitter, &outData) { sawData = true }
                                else { outOpen = false }
                            } else if descriptors[0].revents & (Int16(POLLHUP) | Int16(POLLNVAL)) != 0 {
                                outOpen = false // HUP without readable bytes: truly drained
                            }
                        }
                        if errOpen {
                            if descriptors[1].revents & Int16(POLLIN) != 0 {
                                if drain(errFD, &errSplitter, &errData) { sawData = true }
                                else { errOpen = false }
                            } else if descriptors[1].revents & (Int16(POLLHUP) | Int16(POLLNVAL)) != 0 {
                                errOpen = false
                            }
                        }
                        if sawData { quietWindows = 0 }
                    } else if ready == 0 {
                        if processExited.isSet {
                            quietWindows += 1
                            if quietWindows >= 2 { break }
                        }
                    } else if errno != EINTR {
                        break
                    }
                }
                for line in outSplitter.finish() { onLine(line) }
                for line in errSplitter.finish() { onLine(line) }
                close(outFD)
                close(errFD)
                continuation.resume(returning: (outData, errData))
            }
        }
        }

        nonisolated(unsafe) let proc = process
        try process.run()

        // Watchdog poll: brew can be quiet for long stretches (a git clone during
        // `brew tap`), and cancel() must land even with no output to key off.
        // interrupt() sends SIGINT — brew traps it and exits 130 (brew.rb:22).
        // Grandchildren brew spawned (git, curl) may finish their current step;
        // the inventory re-read that follows a cancelled action reports the truth.
        let watchdog = Task {
            while proc.isRunning {
                if cancellation.isCancelled { proc.interrupt(); break }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        if cancellation.isCancelled { process.interrupt() } // cancelled before the run began

        await process.waitUntilExit()
        processExited.set()
        watchdog.cancel()
        let streams = await readTask.value
        return BrewResult(exitCode: process.terminationStatus, stdout: streams.stdout, stderr: streams.stderr)
    }
}
