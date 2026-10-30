import Foundation
import Observation

/// Per-package version-history state for the detail page (§21). Kept out of
/// InventoryModel: changelog sources are gh/git/GitHub REST, never brew, so
/// they share none of the inventory's brew-mutual-exclusion choreography.
@MainActor
@Observable
public final class VersionHistoryModel {
    public enum Status: Equatable {
        case idle
        case loading
        case loaded(entries: [VersionHistoryEntry], origin: String, fetchedAt: Date)
        case failed(message: String)
    }

    /// GitHub packaging history barely moves within a work session; 30 min per
    /// package keeps reselects free without serving week-old timelines forever.
    public static let cacheTTL: TimeInterval = 1800

    public private(set) var statuses: [String: Status] = [:]

    private struct Cache {
        let entries: [VersionHistoryEntry]
        let origin: String
        let fetchedAt: Date
    }

    private var caches: [String: Cache] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var fetcher: VersionHistoryFetcher

    public init(fetcher: VersionHistoryFetcher) {
        self.fetcher = fetcher
    }

    /// Settings → Changelogs pushes changes live (same posture as the greedy
    /// toggle). A changed access invalidates caches: a token/gh switch must
    /// re-prove the GitHub sources rather than serve the old attempt.
    public func configure(source: ChangelogSource, token: String) {
        var access = VersionHistoryFetcher.Access()
        access.source = source
        access.token = token
        guard access != fetcher.access else { return }
        fetcher.access = access
        caches = [:]
        statuses = [:]
    }

    public func status(for item: BrewItem) -> Status { statuses[item.id] ?? .idle }

    /// Loads (or serves cached) history for one package. Different packages
    /// may load concurrently — only one fetch per package at a time.
    public func load(for item: BrewItem, taps: [TapInfo], force: Bool = false) async {
        if let existing = tasks[item.id] { await existing.value; return } // single flight
        if !force, let cache = caches[item.id],
           Date().timeIntervalSince(cache.fetchedAt) < Self.cacheTTL {
            statuses[item.id] = .loaded(entries: cache.entries, origin: cache.origin, fetchedAt: cache.fetchedAt)
            return
        }
        let task = Task {
            statuses[item.id] = .loading
            let route = historyRoute(for: item, taps: taps)
            do {
                let entries = try await fetcher.fetch(route: route, name: item.name)
                let origin = Self.origin(of: route)
                let now = Date()
                caches[item.id] = Cache(entries: entries, origin: origin, fetchedAt: now)
                statuses[item.id] = .loaded(entries: entries, origin: origin, fetchedAt: now)
            } catch let error as VersionHistoryError {
                statuses[item.id] = .failed(message: error.message)
            } catch {
                statuses[item.id] = .failed(message: error.localizedDescription)
            }
        }
        tasks[item.id] = task
        await task.value
        tasks[item.id] = nil
    }

    /// Caption material: which source this timeline came from (§21).
    private static func origin(of route: HistoryRoute) -> String {
        switch route {
        case .github(let repo, let path): return "GitHub \(repo) · \(path)"
        case .tapGit(_, let file): return "tap git · \(file)"
        case .unsupported: return ""
        }
    }
}
