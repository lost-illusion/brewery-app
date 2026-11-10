import Foundation

/// A (package, target version) pair — the notification dedup key from the design
/// doc: a *new* bump re-announces even when the outdated total is unchanged.
public struct UpdateKey: Hashable, Codable, Sendable {
    public let kind: BrewItem.Kind
    public let fullName: String
    public let targetVersion: String

    public init(kind: BrewItem.Kind, fullName: String, targetVersion: String) {
        self.kind = kind
        self.fullName = fullName
        self.targetVersion = targetVersion
    }
}

/// Notification eligibility (design §Notification content & dedup): only concrete
/// `.updateAvailable` pairs. Pinned rows stay visible in the GUI but are excluded;
/// `.selfUpdating` (greedy/auto-updating casks) and `.unknown` are never announced
/// — no repeated `:latest` nagging.
public func eligibleUpdateKeys(items: [BrewItem]) -> Set<UpdateKey> {
    var keys: Set<UpdateKey> = []
    for item in items {
        guard !item.isPinned else { continue }
        if case .updateAvailable(let latest) = item.outdated {
            keys.insert(UpdateKey(kind: item.kind, fullName: item.fullName, targetVersion: latest))
        }
    }
    return keys
}

public struct UpdateDigestText: Sendable, Equatable {
    public let title: String
    public let body: String
}

/// One digest, not per-package banners. The digest states the current total;
/// the *dedup* is per (package, version) — see `digestDecision`.
public func updateDigestText(eligible: Set<UpdateKey>) -> UpdateDigestText {
    let formulae = eligible.filter { $0.kind == .formula }.count
    let casks = eligible.count - formulae
    let title = eligible.count == 1
        ? "1 package has a newer version"
        : "\(eligible.count) packages have newer versions"
    var parts: [String] = []
    if formulae > 0 { parts.append("\(formulae) formula\(formulae == 1 ? "" : "e")") }
    if casks > 0 { parts.append("\(casks) cask\(casks == 1 ? "" : "s")") }
    let body = parts.isEmpty
        ? "Open brewery to review."
        : "\(parts.joined(separator: " and ")). Open brewery to review."
    return UpdateDigestText(title: title, body: body)
}

public struct UpdateNotifyState: Codable, Sendable, Equatable {
    public var version: Int = 1
    /// Pairs already covered by a delivered digest; pruned when they stop being
    /// outdated so a future reappearance can announce again.
    public var announced: Set<UpdateKey> = []
    public var lastDigestAt: Date?
    public var lastCheckAt: Date?

    public init() {}
}

public struct UpdateNotifyStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("update-notifications.json")
    }

    /// Fresh start (no file yet): empty state — an enable-time initial backlog
    /// digest is allowed (design §Notification content & dedup).
    /// A corrupt/unreadable existing file returns nil: the caller must suppress
    /// notifications this cycle. A silent read/write failure would re-ban
    /// already-announced pairs, so HistoryCache's `try?` posture is wrong here.
    public func load() -> UpdateNotifyState? {
        if !FileManager.default.fileExists(atPath: fileURL.path) { return UpdateNotifyState() }
        do { return try JSONDecoder().decode(UpdateNotifyState.self, from: Data(contentsOf: fileURL)) }
        catch { return nil }
    }

    public func save(_ state: UpdateNotifyState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

public enum DigestAction: Sendable, Equatable {
    case announce(text: UpdateDigestText, total: Int)
    /// New pairs exist but the digest cooldown has not elapsed — they stay
    /// unannounced and the next eligible check carries them.
    case deferredNew
    /// No new pairs, but some announced pairs are still outdated — the delivered
    /// digest still describes reality and must stay in Notification Center.
    case nothing
    /// Nothing eligible at all: any delivered digest is stale and may be withdrawn.
    case backlogResolved
}

public struct DigestOutcome: Sendable {
    public let action: DigestAction
    /// State to persist. `.deferredNew` still advances `lastCheckAt` but leaves
    /// `announced` untouched, so the new pairs stay pending.
    public let newState: UpdateNotifyState?
}

/// Background check cadence — the in-app NSBackgroundActivityScheduler tick and
/// the LaunchAgent's hourly StartCalendarInterval. (Addendum 2026-11-02: the
/// daily cadence lagged external-tap bumps by a day or more.)
public let updateCheckInterval: TimeInterval = 3_600
/// Minimum spacing between interrupting digests. A new pair arriving within it
/// defers to the next check past the cooldown; with the hourly check a bump is
/// announced within about one check, while the per-pair dedup keeps repeat
/// nagging at zero.
public let updateDigestInterval: TimeInterval = 3_600

/// One successful check's decision: what to persist and whether a digest fires now.
/// Announce marks *all* currently eligible pairs as announced (the digest names the
/// whole total), so backlog pairs that waited out a defer window land in this digest.
public func digestDecision(current: Set<UpdateKey>, stored: UpdateNotifyState,
                          now: Date, interval: TimeInterval = updateDigestInterval) -> DigestOutcome {
    let new = current.subtracting(stored.announced)
    var next = stored
    next.lastCheckAt = now

    guard !new.isEmpty else {
        next.announced = stored.announced.intersection(current)
        return DigestOutcome(action: current.isEmpty ? .backlogResolved : .nothing, newState: next)
    }
    if let last = stored.lastDigestAt, now.timeIntervalSince(last) < interval {
        return DigestOutcome(action: .deferredNew, newState: next)
    }
    next.announced = current
    next.lastDigestAt = now
    return DigestOutcome(action: .announce(text: updateDigestText(eligible: current), total: current.count),
                         newState: next)
}

/// Gate 5 tail (2026-11-10): the coordinator persists `announced` *before*
/// posting (at-most-once ordering), so a digest whose UN delivery errored would
/// otherwise be swallowed — every later check sees the pairs as "already
/// announced" and the banner never returns. Un-announce exactly the failed
/// digest's pairs so the next eligible check re-posts. `lastDigestAt` stays:
/// the retry waits out at most one digest cooldown instead of re-firing hot.
public func reArmAnnounced(_ state: UpdateNotifyState, failed: Set<UpdateKey>) -> UpdateNotifyState {
    var next = state
    next.announced.subtract(failed)
    return next
}
