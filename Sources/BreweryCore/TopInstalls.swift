import Foundation

/// Which analytics window the Brew page shows. Raw values are the live URL
/// path suffixes (verified 2026-10-30; compatibilities §24).
public enum AnalyticsPeriod: String, CaseIterable, Sendable, Codable {
    case d30 = "30d", d90 = "90d", d365 = "365d"

    /// Short picker label: "30" / "90" / "365".
    public var label: String { String(rawValue.dropLast()) }
}

/// One row of the Brew section: a package's install count from Homebrew's
/// public analytics (formulae.brew.sh; compatibilities §24), for the window
/// the fetch requested. Not inventory data — a row can name a package this
/// machine has never installed.
public struct TopInstall: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case formula, cask }

    public let name: String
    public let kind: Kind
    public let installs: Int
    public let desc: String?
    /// formulae.brew.sh package page (opened in the browser, like §21's GitHub links).
    public let pageURL: URL

    /// Same shape as BrewItem.id (formula name / cask token), so a row that is
    /// also installed selects the same detail page as the inventory lists.
    public var id: String { name }

    public init(name: String, kind: Kind, installs: Int, desc: String?, pageURL: URL) {
        self.name = name
        self.kind = kind
        self.installs = installs
        self.desc = desc
        self.pageURL = pageURL
    }
}

public struct TopInstallsResult: Sendable, Codable {
    /// Ranked independently — the Brew page shows them as two columns,
    /// formulae left, casks right. `limit` applies per kind.
    public let formulae: [TopInstall]
    public let casks: [TopInstall]
    public let fetchedAt: Date
    /// The analytics window the counts cover, verbatim from the payload
    /// ("2026-09-29" … "2026-10-29"); nil when the payload omitted them.
    public let windowStart: String?
    public let windowEnd: String?
}

/// Seam so tests fake the analytics without HTTP (same posture as HTTPFetching).
public protocol TopInstallsFetching: Sendable {
    func fetchTopInstalls(now: Date, limit: Int, period: AnalyticsPeriod, force: Bool) async throws -> TopInstallsResult
}

public struct TopInstallsFetcher: TopInstallsFetching {
    public let http: HTTPFetching
    public let cacheURL: URL

    /// Analytics windows advance daily; one live fetch per period per day is
    /// plenty (same freshness posture as the manifest cache, design §Freshness).
    public static let cacheLifetime: TimeInterval = 86_400

    public init(http: HTTPFetching = LiveHTTP(), cacheURL: URL = TopInstallsFetcher.defaultCacheURL()) {
        self.http = http
        self.cacheURL = cacheURL
    }

    public static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brewery", isDirectory: true)
            .appendingPathComponent("top-installs-cache.json")
    }

    /// Fresh-cache shortcut (fetchedAt within 24 h of now), otherwise live
    /// download + cache write. `force: true` (the pane's Refresh) bypasses the
    /// shortcut; a failed download falls back to the cached copy of that period
    /// even when stale — stale data beats no data (same rule as ManifestFetcher).
    public func fetchTopInstalls(now: Date, limit: Int, period: AnalyticsPeriod, force: Bool) async throws -> TopInstallsResult {
        let cached = readCache()
        if !force, let hit = cached[period], now.timeIntervalSince(hit.fetchedAt) < Self.cacheLifetime {
            return hit
        }
        do {
            let result = try await fetchLive(now: now, limit: limit, period: period)
            var updated = cached
            updated[period] = result
            writeCache(updated)
            return result
        } catch {
            if let hit = cached[period] { return hit }
            throw error
        }
    }

    public static func analyticsURL(_ kind: TopInstall.Kind, _ period: AnalyticsPeriod) -> URL {
        // The old aggregate paths (/api/analytics/install/30.json) 404 — the live
        // shape is tap-scoped with a period suffix (compatibilities §24).
        switch kind {
        case .formula: URL(string: "https://formulae.brew.sh/api/analytics/install/homebrew-core/\(period.rawValue).json")!
        case .cask:    URL(string: "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/\(period.rawValue).json")!
        }
    }

    static func packageURL(_ name: String, _ kind: TopInstall.Kind) -> URL {
        switch kind {
        case .formula: URL(string: "https://formulae.brew.sh/api/formula/\(name).json")!
        case .cask:    URL(string: "https://formulae.brew.sh/api/cask/\(name).json")!
        }
    }

    public static func pageURL(_ name: String, _ kind: TopInstall.Kind) -> URL {
        switch kind {
        case .formula: URL(string: "https://formulae.brew.sh/formula/\(name)")!
        case .cask:    URL(string: "https://formulae.brew.sh/cask/\(name)")!
        }
    }

    private func fetchLive(now: Date, limit: Int, period: AnalyticsPeriod) async throws -> TopInstallsResult {
        async let formulaData = http.data(from: Self.analyticsURL(.formula, period))
        async let caskData = http.data(from: Self.analyticsURL(.cask, period))
        let formulaPayload = try Self.decodeAnalytics(try await formulaData)
        let caskPayload = try Self.decodeAnalytics(try await caskData)

        // Each kind ranks its own top list (the page columns them side by side);
        // a cask with more installs than a formula does not bump the formula list.
        let formulae = Array(Self.rankedRows(formulaPayload, kind: .formula).sorted { $0.installs > $1.installs }.prefix(limit))
        let casks = Array(Self.rankedRows(caskPayload, kind: .cask).sorted { $0.installs > $1.installs }.prefix(limit))

        return TopInstallsResult(formulae: await enrich(formulae), casks: await enrich(casks),
                                 fetchedAt: now,
                                 windowStart: formulaPayload.windowStart ?? caskPayload.windowStart,
                                 windowEnd: formulaPayload.windowEnd ?? caskPayload.windowEnd)
    }

    /// Descriptions are not in the analytics payload: enrich only the visible
    /// rows, one small per-package JSON each, fetched concurrently.
    /// A failed/404 package read leaves desc nil — the row (name + count) stands.
    private func enrich(_ rows: [TopInstall]) async -> [TopInstall] {
        await withTaskGroup(of: (index: Int, desc: String?).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask {
                    guard let data = try? await self.http.data(from: Self.packageURL(row.name, row.kind)),
                          let desc = try? JSONDecoder().decode(PackageDesc.self, from: data).desc
                    else { return (index, nil) }
                    return (index, desc)
                }
            }
            var descs = [String?](repeating: nil, count: rows.count)
            for await (index, desc) in group { descs[index] = desc }
            return zip(rows, descs).map { row, desc in
                TopInstall(name: row.name, kind: row.kind, installs: row.installs,
                           desc: desc, pageURL: Self.pageURL(row.name, row.kind))
            }
        }
    }

    private struct PackageDesc: Decodable { let desc: String? }

    private struct AnalyticsPayload: Decodable {
        struct Entry: Decodable {
            let formula: String?
            let cask: String?
            let count: String?
        }
        let formulae: [String: [Entry]]
        let windowStart: String?
        let windowEnd: String?

        enum CodingKeys: String, CodingKey {
            case formulae
            case windowStart = "start_date"
            case windowEnd = "end_date"
        }
    }

    private static func decodeAnalytics(_ data: Data) throws -> AnalyticsPayload {
        try JSONDecoder().decode(AnalyticsPayload.self, from: data)
    }

    private static func rankedRows(_ payload: AnalyticsPayload, kind: TopInstall.Kind) -> [TopInstall] {
        payload.formulae.compactMap { name, entries in
            // Each key maps to an array that also carries variants
            // ("wget --HEAD"); the entry naming the key itself is the package.
            guard let base = entries.first(where: { ($0.formula ?? $0.cask) == name }),
                  let raw = base.count
            else { return nil }
            // Counts arrive comma-grouped as strings: "6,672".
            guard let count = Int(raw.filter { $0 != "," }) else { return nil }
            return TopInstall(name: name, kind: kind, installs: count, desc: nil,
                              pageURL: pageURL(name, kind))
        }
    }

    private func readCache() -> [AnalyticsPeriod: TopInstallsResult] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode([AnalyticsPeriod: TopInstallsResult].self, from: data)
        else { return [:] }
        return cache
    }

    private func writeCache(_ cache: [AnalyticsPeriod: TopInstallsResult]) {
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? encoded.write(to: cacheURL, options: .atomic)
    }
}
