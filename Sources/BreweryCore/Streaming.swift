import Foundation

// MARK: - Cancellation

/// One-shot cancellation for a brew process the app started. `cancel()` is safe
/// from any thread, more than once, or before the run begins (runners also check
/// `isCancelled` at start). Production runners respond with SIGINT: brew traps
/// INT and exits 130 (`brew.rb:22`, `std_trap = trap("INT") { exit! 130 }`), the
/// same path Ctrl-C takes in a terminal.
public final class BrewCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

// MARK: - Line splitting

/// Splits a byte stream arriving in arbitrary chunks into complete output lines.
/// Terminators: `\n`, `\r\n` (as one), and bare `\r` — brew rewrites its download
/// progress bar with `\r`, so each frame arrives as its own line here and
/// `appendProgressLines` folds consecutive frames together.
/// Multi-byte UTF-8 straddling a chunk boundary stays in the buffer until its line
/// completes: decoding happens only on whole-line boundaries, and a line boundary
/// never cuts a character (no UTF-8 continuation byte is 0x0A/0x0D).
public struct BrewLineSplitter {
    private var bytes: [UInt8] = []
    // Defensive flush for a giant unterminated line (brew never writes one, but the
    // buffer must not grow unbounded if something else does).
    private let maxLineBytes = 4096
    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        bytes.append(contentsOf: chunk)
        var lines: [String] = []
        var lineStart = 0
        var consumed = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0A || b == 0x0D {
                if i > lineStart { lines.append(String(decoding: Array(bytes[lineStart..<i]), as: UTF8.self)) }
                i += 1
                if b == 0x0D, i < bytes.count, bytes[i] == 0x0A { i += 1 } // \r\n is one terminator
                lineStart = i
                consumed = i
            } else {
                i += 1
            }
        }
        if lineStart < bytes.count, bytes.count - lineStart >= maxLineBytes {
            lines.append(String(decoding: Array(bytes[lineStart...]), as: UTF8.self))
            consumed = bytes.count
        }
        if consumed > 0 { bytes.removeFirst(consumed) }
        return lines
    }

    /// Flushes bytes left over at EOF (a final line without a terminator).
    public mutating func finish() -> [String] {
        defer { bytes = [] }
        guard !bytes.isEmpty else { return [] }
        return [String(decoding: bytes, as: UTF8.self)]
    }
}

// MARK: - Progress buffer

/// brew's message lines carry a prefix or prose ("==> Fetching", "Warning:", a
/// caveat). Its in-place progress bar occupies the line start with `#` (curl-style
/// frames: `#####  =  36% of  11.2MB`); a leading `=` that is not the `==>` message
/// prefix belongs to bar rendering too.
public func isBrewProgressBarLine(_ line: String) -> Bool {
    let t = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let first = t.first else { return false }
    if first == "#" { return true }
    return first == "=" && !t.hasPrefix("==>")
}

/// Appends streamed lines to the sheet buffer: consecutive bar frames replace each
/// other (brew rewrites the bar hundreds of times per \r; the sheet only needs the
/// latest frame), and the buffer stays capped at `maxLines` (the oldest lines go).
public func appendProgressLines(_ lines: [String], to buffer: inout [String], maxLines: Int = 300) {
    for line in lines {
        if isBrewProgressBarLine(line), let last = buffer.last, isBrewProgressBarLine(last) {
            buffer[buffer.count - 1] = line
        } else {
            buffer.append(line)
        }
    }
    if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
}

// MARK: - Streaming seam on CommandRunning

extension CommandRunning {
    /// Default for runners that cannot stream (and therefore cannot be interrupted
    /// mid-run): run buffered, then yield stdout lines followed by stderr lines.
    /// `BrewRunner` overrides this with true line streaming + SIGINT cancellation;
    /// test fakes that need cancellation override it too.
    public func runStreaming(_ args: [String], onLine: @escaping @Sendable (String) -> Void,
                             cancellation: BrewCancellationToken) async throws -> BrewResult {
        let result = try await run(args)
        var out = BrewLineSplitter()
        for line in out.feed(result.stdout) { onLine(line) }
        for line in out.finish() { onLine(line) }
        var err = BrewLineSplitter()
        for line in err.feed(result.stderr) { onLine(line) }
        for line in err.finish() { onLine(line) }
        return result
    }
}
