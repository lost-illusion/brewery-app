import Foundation
import Testing

@testable import BreweryCore

// Live payload shapes from 2026-10-30 (compatibilities §24), trimmed:
// comma-grouped string counts, "name --HEAD" variants inside each array,
// cask entries keyed "cask" inside the same "formulae" dict.
private let formulaAnalytics = """
{"category":"formula_install","total_items":4,"start_date":"2026-09-29","end_date":"2026-10-29","total_count":100,
 "formulae":{
  "wget":[{"formula":"wget","count":"40,673"},{"formula":"wget --HEAD","count":"81"}],
  "openssl@3":[{"formula":"openssl@3","count":"1,234,567"}],
  "nullossay":[{"formula":"nullossay","count":"not-a-number"}],
  "glibc":[{"formula":"glibc --HEAD","count":"5"}],
  "libr":[{"formula":"libr","count":"6,000"}]
 }}
"""

private let caskAnalytics = """
{"category":"cask_install","total_items":1,"start_date":"2026-09-29","end_date":"2026-10-29","total_count":10,
 "formulae":{"1password":[{"cask":"1password","count":"6,672"}]}}
"""

private let packageJSONs: [String: String] = [
    "https://formulae.brew.sh/api/formula/wget.json": #"{"name":"wget","desc":"Network downloader"}"#,
    "https://formulae.brew.sh/api/formula/openssl@3.json": #"{"name":"openssl@3","desc":"Universal SSL/TLS and Cryptography Toolkit"}"#,
    "https://formulae.brew.sh/api/cask/1password.json": #"{"token":"1password","desc":"Password manager"}"#,
    // libr deliberately absent: its per-package read 404s → desc stays nil, row survives.
]

private struct HTTPNotFound: Error {}

/// Period-agnostic fake: serves the same analytics shape for any 30d/90d/365d
/// path so the URL suffix itself is what the fetcher is tested against.
private struct FakeAnalyticsHTTP: HTTPFetching {
    func data(from url: URL) async throws -> Data {
        let s = url.absoluteString
        if s.contains("/analytics/install/homebrew-core/") { return Data(formulaAnalytics.utf8) }
        if s.contains("/analytics/cask-install/homebrew-cask/") { return Data(caskAnalytics.utf8) }
        guard let json = packageJSONs[s] else { throw HTTPNotFound() }
        return Data(json.utf8)
    }
}

private final class CountingHTTP: HTTPFetching, @unchecked Sendable {
    private(set) var analyticsCalls = 0
    func data(from url: URL) async throws -> Data {
        let s = url.absoluteString
        if s.contains("/analytics/") { analyticsCalls += 1 }
        if s.contains("/analytics/install/homebrew-core/") { return Data(formulaAnalytics.utf8) }
        if s.contains("/analytics/cask-install/homebrew-cask/") { return Data(caskAnalytics.utf8) }
        guard let json = packageJSONs[s] else { throw HTTPNotFound() }
        return Data(json.utf8)
    }
}

private struct FailingHTTP: HTTPFetching {
    func data(from url: URL) async throws -> Data { throw HTTPNotFound() }
}

private func tempCacheURL(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("top-installs-cache-\(label)-\(UUID().uuidString)")
        .appendingPathComponent("top-installs-cache.json")
}

@Suite struct TopInstallsFetcherTests {
    @Test func ranksFormulaeAndCasksSeparatelyAndEnrichesDescs() async throws {
        let fetcher = TopInstallsFetcher(http: FakeAnalyticsHTTP(), cacheURL: tempCacheURL("rank"))
        let result = try await fetcher.fetchTopInstalls(now: Date(timeIntervalSince1970: 1), limit: 4, period: .d30, force: false)

        // Separate top lists per kind (the page's two columns): 1password's
        // 6,672 does not rank into the formula list despite beating libr.
        #expect(result.formulae.map(\.name) == ["openssl@3", "wget", "libr"])
        #expect(result.formulae.map(\.installs) == [1_234_567, 40_673, 6_000])
        #expect(result.casks.map(\.name) == ["1password"])
        #expect(result.casks.map(\.kind) == [.cask])
        #expect(result.formulae[0].desc == "Universal SSL/TLS and Cryptography Toolkit")
        #expect(result.formulae[1].desc == "Network downloader")
        #expect(result.casks[0].desc == "Password manager")
        // 404 on the per-package read: row keeps name+count, desc nil.
        #expect(result.formulae[2].desc == nil)
        #expect(result.fetchedAt == Date(timeIntervalSince1970: 1))
        #expect(result.windowStart == "2026-09-29")
        #expect(result.windowEnd == "2026-10-29")
    }

    @Test func headVariantsAndUnparseableCountsAreSkipped() async throws {
        let fetcher = TopInstallsFetcher(http: FakeAnalyticsHTTP(), cacheURL: tempCacheURL("head"))
        let result = try await fetcher.fetchTopInstalls(now: Date(), limit: 100, period: .d30, force: false)
        // "wget --HEAD" (81) never ranks as its own row; the wget row is the
        // base entry (40,673), not the sum. glibc (only a --HEAD entry) and
        // nullossay (count not a number) drop out entirely.
        #expect(!result.formulae.contains { $0.name.contains("--HEAD") })
        #expect(!result.formulae.contains { $0.name == "glibc" || $0.name == "nullossay" })
        #expect(result.formulae.filter { $0.name == "wget" }.map(\.installs) == [40_673])
    }

    @Test func limitAppliesPerKind() async throws {
        let fetcher = TopInstallsFetcher(http: FakeAnalyticsHTTP(), cacheURL: tempCacheURL("limit"))
        let result = try await fetcher.fetchTopInstalls(now: Date(), limit: 2, period: .d30, force: false)
        #expect(result.formulae.map(\.name) == ["openssl@3", "wget"])
        #expect(result.casks.map(\.name) == ["1password"]) // the cask list has only one entry; the limit doesn't merge kinds
    }

    @Test func periodsMapToTheirAnalyticsURLs() {
        #expect(TopInstallsFetcher.analyticsURL(.formula, .d30).absoluteString
            == "https://formulae.brew.sh/api/analytics/install/homebrew-core/30d.json")
        #expect(TopInstallsFetcher.analyticsURL(.cask, .d90).absoluteString
            == "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/90d.json")
        #expect(TopInstallsFetcher.analyticsURL(.formula, .d365).path.hasSuffix("/homebrew-core/365d.json"))
    }

    @Test func pageURLsAreSitePagesNotAPIURLs() {
        #expect(TopInstallsFetcher.pageURL("wget", .formula).absoluteString == "https://formulae.brew.sh/formula/wget")
        #expect(TopInstallsFetcher.pageURL("1password", .cask).absoluteString == "https://formulae.brew.sh/cask/1password")
    }
}

@Suite struct TopInstallsCacheTests {
    @Test func freshCacheServesWithoutHTTPStaleAndForceRefetch() async throws {
        let http = CountingHTTP()
        let fetcher = TopInstallsFetcher(http: http, cacheURL: tempCacheURL("fresh"))
        let now = Date(timeIntervalSince1970: 1_000_000)

        _ = try await fetcher.fetchTopInstalls(now: now, limit: 4, period: .d30, force: false)
        #expect(http.analyticsCalls == 2) // formula + cask payloads

        // 1 h later, same period: the 24 h disk cache answers without HTTP.
        let cached = try await fetcher.fetchTopInstalls(now: now.addingTimeInterval(3600), limit: 4, period: .d30, force: false)
        #expect(http.analyticsCalls == 2)
        #expect(cached.formulae.map(\.name) == ["openssl@3", "wget", "libr"])
        #expect(cached.casks.map(\.name) == ["1password"])
        #expect(cached.fetchedAt == now) // the cache keeps the ORIGINAL fetchedAt, not "now"

        // A different period is a different cache entry → live fetch.
        _ = try await fetcher.fetchTopInstalls(now: now, limit: 4, period: .d90, force: false)
        #expect(http.analyticsCalls == 4)

        // Past the 24 h lifetime the next read refetches.
        _ = try await fetcher.fetchTopInstalls(now: now.addingTimeInterval(86_401), limit: 4, period: .d30, force: false)
        #expect(http.analyticsCalls == 6)

        // force: true (the pane's Refresh) bypasses even a fresh cache.
        _ = try await fetcher.fetchTopInstalls(now: now.addingTimeInterval(1), limit: 4, period: .d30, force: true)
        #expect(http.analyticsCalls == 8)
    }

    @Test func failedLiveFetchFallsBackToStaleCacheButEmptyCacheThrows() async throws {
        let cacheURL = tempCacheURL("offline")
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try await TopInstallsFetcher(http: FakeAnalyticsHTTP(), cacheURL: cacheURL)
            .fetchTopInstalls(now: now, limit: 4, period: .d30, force: false)

        // Same cache, failing network, window expired: last-good data is served.
        let offline = TopInstallsFetcher(http: FailingHTTP(), cacheURL: cacheURL)
        let stale = try await offline.fetchTopInstalls(now: now.addingTimeInterval(86_401), limit: 4, period: .d30, force: false)
        #expect(stale.formulae.map(\.name) == ["openssl@3", "wget", "libr"])

        // Nothing cached for that period and the network fails: the error surfaces.
        do {
            _ = try await offline.fetchTopInstalls(now: now, limit: 4, period: .d365, force: false)
            Issue.record("expected a thrown fetch failure")
        } catch { }
    }
}

private struct IdleRunner: CommandRunning {
    func run(_ args: [String]) async throws -> BrewResult {
        BrewResult(exitCode: 1, stdout: Data(), stderr: Data("unscripted args: \(args)".utf8))
    }
}

private struct IdleProbe: ExternalBrewProbing {
    func isBrewRunningExternally() -> Bool { false }
}

private actor CountingTopInstallsFetcher: TopInstallsFetching {
    private(set) var calls = 0
    func fetchTopInstalls(now: Date, limit: Int, period: AnalyticsPeriod, force: Bool) async throws -> TopInstallsResult {
        calls += 1
        let row = TopInstall(name: "wget", kind: .formula, installs: 1, desc: nil,
                             pageURL: URL(string: "https://formulae.brew.sh/formula/wget")!)
        return TopInstallsResult(formulae: [row], casks: [], fetchedAt: now, windowStart: nil, windowEnd: nil)
    }
}

@Suite struct TopInstallsModelTests {
    @MainActor
    @Test func loadOncePerPeriodPerLaunchAndOnlyForceRefetches() async throws {
        let fetcher = CountingTopInstallsFetcher()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("top-installs-model-test-\(UUID().uuidString)")
        let model = InventoryModel(runner: IdleRunner(),
                                   manifestFetcher: ManifestFetcher(http: FakeAnalyticsHTTP(),
                                       cacheURL: dir.appendingPathComponent("manifest-cache.json")),
                                   store: SnapshotStore(directory: dir),
                                   brewProbe: IdleProbe(),
                                   jqAvailable: true, settings: InventorySettings(),
                                   topInstallsFetcher: fetcher)

        await model.loadTopInstalls(period: .d30)
        #expect(model.topInstallsState == .ready)
        #expect(model.topInstalls[.d30]?.formulae.count == 1)

        await model.loadTopInstalls(period: .d30) // lazy shortcut: a loaded period is not refetched
        #expect(await fetcher.calls == 1)

        await model.loadTopInstalls(period: .d90) // a different picker window asks the fetcher
        #expect(await fetcher.calls == 2)
        #expect(model.topInstalls[.d90] != nil)

        await model.loadTopInstalls(period: .d30, force: true) // the pane's Refresh bypasses the shortcut
        #expect(await fetcher.calls == 3)
    }
}
