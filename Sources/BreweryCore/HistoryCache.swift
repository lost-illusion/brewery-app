import Foundation

/// How long fetched version-history data stays reusable (§23). The Settings →
/// Changelogs picker stores the rawValue in preferences; `.endless` keeps
/// every entry until the "Clear cache" button removes them.
public enum HistoryCacheRetention: String, CaseIterable, Identifiable, Sendable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case endless

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .endless: "No expiry"
        }
    }

    /// nil = endless; age is checked per read so a shortened retention
    /// invalidates old entries without deleting them until the next fetch.
    public var timeInterval: TimeInterval? {
        switch self {
        case .sevenDays: 7 * 86_400
        case .thirtyDays: 30 * 86_400
        case .ninetyDays: 90 * 86_400
        case .endless: nil
        }
    }
}

/// One cached packaging timeline (decodes live from HistoryCacheStore; the
/// model also uses it as its in-memory cache value).
public struct HistoryRecord: Codable, Equatable {
    public let entries: [VersionHistoryEntry]
    public let origin: String
    public let fetchedAt: Date

    public init(entries: [VersionHistoryEntry], origin: String, fetchedAt: Date) {
        self.entries = entries
        self.origin = origin
        self.fetchedAt = fetchedAt
    }
}

/// One cached upstream-release list; fetchedAt is cache bookkeeping, never shown.
public struct ReleaseRecord: Codable, Equatable {
    public let releases: [UpstreamRelease]
    public let fetchedAt: Date

    public init(releases: [UpstreamRelease], fetchedAt: Date) {
        self.releases = releases
        self.fetchedAt = fetchedAt
    }
}

public struct HistoryCacheSnapshot: Codable, Equatable {
    public var histories: [String: HistoryRecord]
    public var releases: [String: ReleaseRecord]

    public init(histories: [String: HistoryRecord] = [:], releases: [String: ReleaseRecord] = [:]) {
        self.histories = histories
        self.releases = releases
    }
}

/// One JSON file holding every package's fetched timeline and release list,
/// so re-opening a package is free across launches (§23). Missing or corrupt
/// reads degrade to "nothing cached" — the cache never blocks a fetch.
public final class HistoryCacheStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("history-cache.json")
    }

    public func load() -> HistoryCacheSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(HistoryCacheSnapshot.self, from: data)
        else { return HistoryCacheSnapshot() }
        return snapshot
    }

    /// Best-effort: a failed write costs only next launch's speed-up.
    public func save(_ snapshot: HistoryCacheSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
