import Foundation
import Testing
@testable import BreweryCore

// MARK: - Line splitting

@Test func splitter_splitsNewline_CRLF_and_bareCR() {
    var s = BrewLineSplitter()
    #expect(s.feed(Data("a\nb\r\nc\rd".utf8)) == ["a", "b", "c"]) // \r\n counts as one terminator
    #expect(s.finish() == ["d"]) // trailing partial flushes at EOF
    #expect(s.finish() == [])
}

@Test func splitter_keeps_partial_lines_until_their_terminator_arrives() {
    var s = BrewLineSplitter()
    #expect(s.feed(Data("he".utf8)) == [])
    #expect(s.feed(Data("llo w".utf8)) == [])
    #expect(s.feed(Data("orld\nnext".utf8)) == ["hello world"])
    #expect(s.finish() == ["next"])
}

@Test func splitter_collapses_empty_lines_and_survives_UTF8_cut_mid_character() {
    var s = BrewLineSplitter()
    #expect(s.feed(Data("a\r\n\r\nb\n".utf8)) == ["a", "b"])
    // "é" is 0xC3 0xA9: feed cuts between the two bytes — the character must survive.
    let bytes = Data("héllo\n".utf8)
    var s2 = BrewLineSplitter()
    var out = s2.feed(bytes.prefix(2)) // "h" + first byte of é
    out += s2.feed(Data(bytes.dropFirst(2)))
    #expect(out == ["héllo"])
}

// MARK: - Progress buffer folding

@Test func barLineDetection() {
    #expect(isBrewProgressBarLine("##########        = 34% of 11.2MB"))
    #expect(isBrewProgressBarLine("====> "))
    #expect(!isBrewProgressBarLine("==> Fetching wget"))
    #expect(!isBrewProgressBarLine("Warning: something"))
    #expect(!isBrewProgressBarLine(""))
}

@Test func progress_folds_consecutive_bar_frames_and_caps_the_buffer() {
    var buf: [String] = []
    appendProgressLines(["==> Fetching", "##### 10%", "####### 40%", "######## 90%", "==> Pouring"], to: &buf)
    #expect(buf == ["==> Fetching", "######## 90%", "==> Pouring"]) // only the latest frame survives
    appendProgressLines(["==> Fetching", "==> Installing"], to: &buf, maxLines: 4)
    #expect(buf.count == 4) // cap holds; oldest lines go
    #expect(buf.first == "######## 90%")
}

// MARK: - BrewRunner streaming (real Process)

private final class DeliverySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [(line: String, beforeExit: Bool)] = []
    private var exited = false
    func add(_ line: String) { lock.withLock { _lines.append((line, !exited)) } }
    func markExited() { lock.withLock { exited = true } }
    var lines: [String] { lock.withLock { _lines.map(\.line) } }
    var deliveredWhileRunning: [String] { lock.withLock { _lines.filter(\.beforeExit).map(\.line) } }
}

private func makeStreamingScript(_ content: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brewery-streaming-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("fake-brew.sh")
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test func runStreaming_delivers_lines_while_the_process_is_still_running() async throws {
    let script = try makeStreamingScript("#!/bin/sh\necho one\necho two >&2\nsleep 0.5\necho three\n")
    let sink = DeliverySink()
    let result = try await BrewRunner(brewURL: script).runStreaming([], onLine: { sink.add($0) }, cancellation: BrewCancellationToken())
    sink.markExited() // deliveries after this point would prove nothing
    #expect(sink.lines == ["one", "two", "three"])
    #expect(sink.deliveredWhileRunning.contains("one"))
    #expect(sink.deliveredWhileRunning.contains("two")) // stderr streams too
    #expect(String(data: result.stdout, encoding: .utf8) == "one\nthree\n") // full capture preserved for failure paths
    #expect(String(data: result.stderr, encoding: .utf8) == "two\n")
    #expect(result.exitCode == 0)
}

@Test func runStreaming_cancel_interrupts_a_quiet_process_and_reports_nonzero() async throws {
    // brew-shaped fake: traps INT and exits 130 (the real brew.rb:22 posture).
    // zsh, not /bin/sh: bash 3.2 defers INT traps until the foreground command
    // finishes (verified here — a 10 s wait outlived the interrupt), while zsh runs
    // the trap the moment INT arrives, the way brew's Ruby trap does. The sleep runs
    // backgrounded so `wait` is the interrupted builtin; the trap reaps it.
    let script = try makeStreamingScript("#!/bin/zsh\ntrap 'echo got-int; kill $(jobs -p) 2>/dev/null; exit 130' INT\necho started\nsleep 10 &\nwait\n")
    let token = BrewCancellationToken()
    let sink = DeliverySink()
    let start = ContinuousClock.now
    let runTask = Task {
        try await BrewRunner(brewURL: script).runStreaming([], onLine: { sink.add($0) }, cancellation: token)
    }
    while !sink.lines.contains("started") { try? await Task.sleep(for: .milliseconds(10)) }
    token.cancel()
    let result = try await runTask.value
    let elapsed = start.duration(to: .now)
    #expect(elapsed < .seconds(5)) // a 10 s script died from a 60 ms watchdog, not from finishing
    #expect(result.exitCode == 130)
    #expect(sink.lines.contains("started"))
    #expect(sink.lines.contains("got-int")) // the child's own INT trap ran: the signal was deliverable, not just posted
}

@Test func defaultRunStreaming_buffers_through_run_and_yields_lines() async throws {
    struct BufferedOnlyRunner: CommandRunning {
        func run(_ args: [String]) async throws -> BrewResult {
            BrewResult(exitCode: 0, stdout: Data("a\nb\n".utf8), stderr: Data("e\n".utf8))
        }
    }
    let sink = DeliverySink()
    let result = try await BufferedOnlyRunner().runStreaming(["x"], onLine: { sink.add($0) }, cancellation: BrewCancellationToken())
    #expect(result.exitCode == 0)
    #expect(sink.lines == ["a", "b", "e"]) // stdout then stderr; fakes keep working without a streaming override
}

// MARK: - Model wiring (streaming + cancel)

private final class StreamingFakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let results: [String: BrewResult]
    private let streamLines: [String]
    private let holdUntilCancelled: Bool

    init(results: [String: BrewResult], streamLines: [String], holdUntilCancelled: Bool = false) {
        self.results = results
        self.streamLines = streamLines
        self.holdUntilCancelled = holdUntilCancelled
    }
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ args: [String]) async throws -> BrewResult {
        lock.withLock { _calls.append(args) }
        await Task.yield()
        return results[args.joined(separator: " ")] ?? BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted: \(args)".utf8))
    }

    func runStreaming(_ args: [String], onLine: @escaping @Sendable (String) -> Void,
                      cancellation: BrewCancellationToken) async throws -> BrewResult {
        lock.withLock { _calls.append(args) }
        for line in streamLines { onLine(line) }
        if holdUntilCancelled {
            while !cancellation.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return BrewResult(exitCode: 130, stdout: Data(), stderr: Data()) // the brew INT posture
        }
        await Task.yield()
        return results[args.joined(separator: " ")] ?? BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted: \(args)".utf8))
    }
}

private final class FakeProbeOff: ExternalBrewProbing, @unchecked Sendable {
    func isBrewRunningExternally() -> Bool { false }
}
private final class FakeHTTPJSON: HTTPFetching, @unchecked Sendable {
    func data(from url: URL) async throws -> Data { Data("{}".utf8) }
}

@MainActor
private func makeStreamingModel(lines: [String], holdUntilCancelled: Bool,
                                extra: [String: BrewResult] = [:]) -> (InventoryModel, StreamingFakeRunner) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var results: [String: BrewResult] = [
        "list --json --versions": BrewResult(exitCode: 0, stdout: fixtureData("list.json"), stderr: Data()),
        "info --json=v2 --installed": BrewResult(exitCode: 0, stdout: fixtureData("info.json"), stderr: Data()),
        "tap-info --installed --json": BrewResult(exitCode: 0, stdout: fixtureData("taps.json"), stderr: Data()),
        "trust --json=v1": BrewResult(exitCode: 0, stdout: fixtureData("trust.json"), stderr: Data()),
    ]
    results.merge(extra) { _, new in new }
    let runner = StreamingFakeRunner(results: results, streamLines: lines, holdUntilCancelled: holdUntilCancelled)
    let model = InventoryModel(runner: runner,
                               manifestFetcher: ManifestFetcher(http: FakeHTTPJSON(), cacheURL: dir.appendingPathComponent("manifest.json")),
                               store: SnapshotStore(directory: dir),
                               brewProbe: FakeProbeOff(), jqAvailable: true, settings: InventorySettings())
    return (model, runner)
}

@MainActor
private func waitStream(_ what: String, _ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for: \(what)")
}

@MainActor
@Test func install_streams_progress_live_and_cancel_leaves_a_dismissable_report() async {
    let lines = ["==> Fetching wget", "==> Pouring wget"]
    let (model, runner) = makeStreamingModel(lines: lines, holdUntilCancelled: true)
    let install = Task { await model.installItem("homebrew/cask/wget") }

    await waitStream("install running") { model.progressActionLabel == "Installing homebrew/cask/wget…" }
    await waitStream("live progress in the model") { model.actionProgress == lines }
    #expect(model.isMutating)

    model.cancelAction()
    await install.value

    if case .failed(let action, let message) = model.tapAction {
        #expect(action == .installing(qualified: "homebrew/cask/wget"))
        #expect(message.contains("Cancelled"))
    } else { Issue.record("expected .failed after cancel, got \(model.tapAction)") }
    #expect(!model.isMutating) // a cancel must not re-lock the buttons (the 2026-11-10 deadlock shape)
    // Cancel differs from a brew refusal: partial work can be real, so the model reloads.
    #expect(runner.calls.contains(["install", "-y", "homebrew/cask/wget"]))
    #expect(runner.calls.contains(["tap-info", "--installed", "--json"]))
    #expect(runner.calls.contains(["list", "--json", "--versions"]))
    model.dismissTapAction()
    #expect(model.tapAction == .idle)
}

@MainActor
@Test func install_success_keeps_streamed_lines_after_idle() async {
    let lines = ["==> Installing foo", "==> Summary"]
    let (model, _) = makeStreamingModel(lines: lines, holdUntilCancelled: false,
                                        extra: ["install -y umputun/apps/foo": BrewResult(exitCode: 0, stdout: Data(), stderr: Data())])
    await model.installItem("umputun/apps/foo")
    #expect(model.tapAction == .idle)
    #expect(model.actionProgress == lines) // the tail stays readable; only the sheet closes
}

@MainActor
@Test func upgrade_cancel_reports_failure_and_reloads_badges() async {
    let (model, runner) = makeStreamingModel(lines: ["==> Updating Homebrew"], holdUntilCancelled: true)
    let upgrade = Task { await model.upgradeAll() }
    await waitStream("upgrade running") { model.progressActionLabel == "Updating Homebrew…" }
    // The streamed line lands via the MainActor consumer task — wait for it rather
    // than assume it beat the test to the main-actor queue.
    await waitStream("live upgrade progress in the model") { model.actionProgress == ["==> Updating Homebrew"] }

    model.cancelAction()
    await upgrade.value

    switch model.upgrade {
    case .failed(let message): #expect(message.contains("Cancelled"))
    default: Issue.record("expected .failed after cancel, got \(model.upgrade)")
    }
    #expect(model.progressActionLabel == nil) // the sheet closes on any end state
    #expect(runner.calls.contains(["update"]))
    #expect(!runner.calls.contains(["upgrade", "-y"])) // the chain stopped at the cancelled step
    #expect(runner.calls.contains(["list", "--json", "--versions"])) // partial upgrade → badges must reflect reality
}
