import Foundation
import Observation

/// Per-package version-history state for the detail page (§21). Kept out of
/// InventoryModel: changelog sources are gh/git/GitHub REST, never brew, so
/// they share none of the inventory's brew-mutual-exclusion choreography.
/// Fetched timelines and release lists persist across launches through
/// HistoryCacheStore and stay reusable until the retention picked in
/// Settings → Changelogs expires them (§23).
@MainActor
@Observable
public final class VersionHistoryModel {
    public enum Status: Equatable {
        case idle
        case loading
        case loaded(entries: [VersionHistoryEntry], origin: String, fetchedAt: Date)
        case failed(message: String)
    }

    public enum ReleaseStatus: Equatable {
        case idle
        case loading
        case loaded([UpstreamRelease])
        case failed(message: String)
    }

    public private(set) var statuses: [String: Status] = [:]
    public private(set) var releaseStatuses: [String: ReleaseStatus] = [:]
    public private(set) var retention: HistoryCacheRetention

    private var caches: [String: HistoryRecord] = [:]
    private var releaseCaches: [String: ReleaseRecord] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var releaseTasks: [String: Task<Void, Never>] = [:]
    private var fetcher: VersionHistoryFetcher
    private let store: HistoryCacheStore?

    public init(fetcher: VersionHistoryFetcher,
                store: HistoryCacheStore? = nil,
                retention: HistoryCacheRetention = .thirtyDays) {
        self.fetcher = fetcher
        self.store = store
        self.retention = retention
        if let store {
            let snapshot = store.load()
            caches = snapshot.histories
            releaseCaches = snapshot.releases
            // A retention shortened since the last launch: drop what the new
            // window no longer covers before anything can be served from it.
            pruneExpired()
        }
    }

    /// Settings → Changelogs pushes changes live (same posture as the greedy
    /// toggle). A changed access clears the shown statuses but NOT the cache:
    /// a fetched timeline is the same GitHub data whichever authenticated mode
    /// retrieved it, so a token/gh switch re-serves it instead of refetching.
    public func configure(source: ChangelogSource, token: String) {
        var access = VersionHistoryFetcher.Access()
        access.source = source
        access.token = token
        guard access != fetcher.access else { return }
        fetcher.access = access
        statuses = [:]
        releaseStatuses = [:]
    }

    public func status(for item: BrewItem) -> Status { statuses[item.id] ?? .idle }

    /// Loads (or serves cached) history for one package. Different packages
    /// may load concurrently — only one fetch per package at a time.
    public func load(for item: BrewItem, taps: [TapInfo], force: Bool = false) async {
        if let existing = tasks[item.id] { await existing.value; return } // single flight
        if !force, let cache = caches[item.id], fresh(cache.fetchedAt) {
            statuses[item.id] = .loaded(entries: cache.entries, origin: cache.origin, fetchedAt: cache.fetchedAt)
            return
        }
        let task = Task {
            statuses[item.id] = .loading
            let route = historyRoute(for: item, taps: taps)
            do {
                let entries = try await fetcher.fetch(route: route, name: item.name)
                let origin = Self.origin(of: route)
                let record = HistoryRecord(entries: entries, origin: origin, fetchedAt: Date())
                caches[item.id] = record
                persist()
                statuses[item.id] = .loaded(entries: record.entries, origin: record.origin, fetchedAt: record.fetchedAt)
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

    /// Upstream releases for a GitHub-homepage package (§21). No-op when the
    /// homepage is not a GitHub repo — the view only asks when derivable, and
    /// an undecidable homepage has no release source at all.
    public func loadReleases(for item: BrewItem, force: Bool = false) async {
        guard let repo = upstreamGitHubRepo(homepage: item.homepage) else { return }
        if let existing = releaseTasks[item.id] { await existing.value; return } // single flight
        if !force, let cache = releaseCaches[item.id], fresh(cache.fetchedAt) {
            releaseStatuses[item.id] = .loaded(cache.releases)
            return
        }
        let task = Task {
            releaseStatuses[item.id] = .loading
            do {
                let releases = try await fetcher.fetchReleases(owner: repo.owner, repo: repo.repo)
                let record = ReleaseRecord(releases: releases, fetchedAt: Date())
                releaseCaches[item.id] = record
                persist()
                releaseStatuses[item.id] = .loaded(record.releases)
            } catch let error as VersionHistoryError {
                releaseStatuses[item.id] = .failed(message: error.message)
            } catch {
                releaseStatuses[item.id] = .failed(message: error.localizedDescription)
            }
        }
        releaseTasks[item.id] = task
        await task.value
        releaseTasks[item.id] = nil
    }

    public func releaseStatus(for item: BrewItem) -> ReleaseStatus { releaseStatuses[item.id] ?? .idle }

    /// Settings → Changelogs retention picker. Entries already outside the new
    /// window are pruned from memory and disk immediately.
    public func setRetention(_ retention: HistoryCacheRetention) {
        guard retention != self.retention else { return }
        self.retention = retention
        pruneExpired()
    }

    /// Settings → Changelogs "Clear cache": every cached timeline and release
    /// list goes, disk included; open packages fall back to .idle and refetch
    /// on the next view.
    public func clearCache() {
        caches = [:]
        releaseCaches = [:]
        statuses = [:]
        releaseStatuses = [:]
        store?.clear()
    }

    private func fresh(_ fetchedAt: Date) -> Bool {
        guard let ttl = retention.timeInterval else { return true } // endless
        return Date().timeIntervalSince(fetchedAt) < ttl
    }

    private func pruneExpired() {
        guard retention.timeInterval != nil else { return } // endless keeps everything
        let before = caches.count + releaseCaches.count
        caches = caches.filter { fresh($0.value.fetchedAt) }
        releaseCaches = releaseCaches.filter { fresh($0.value.fetchedAt) }
        if caches.count + releaseCaches.count != before { persist() }
    }

    private func persist() {
        store?.save(HistoryCacheSnapshot(histories: caches, releases: releaseCaches))
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
