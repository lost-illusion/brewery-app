import Foundation
import Testing
@testable import BreweryCore

@Test func manifest_decode_miniFixture() throws {
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-mini.json"))
    #expect(manifest.latestFormulaVersion("ace") == "8.0.8")
    #expect(manifest.latestCaskVersion("wireshark-app") == "4.6.9")
    #expect(manifest.latestFormulaVersion("nope") == nil)
    #expect(manifest.latestCaskVersion("nope") == nil)
}

@Test func manifest_endpointURL() {
    let url = ManifestFetcher.endpointURL(bottleTag: "arm64_golden_gate")
    #expect(url.host == "formulae.brew.sh")
    #expect(url.absoluteString.contains("api/internal")) // /api/... 404s — verified §23
    #expect(url.path.hasSuffix("arm64_golden_gate.jws.json"))
}

@Test func manifest_staleness() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    #expect(ManifestFetcher.isStale(fetchedAt: t0, now: t0.addingTimeInterval(86_401), threshold: 86_400))
    #expect(!ManifestFetcher.isStale(fetchedAt: t0, now: t0.addingTimeInterval(86_399), threshold: 86_400))
}

@Test func manifest_fetchFreshCacheSkipsHTTP() async throws {
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    let first = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    #expect(first.manifest.latestFormulaVersion("ace") == "8.0.8")
    #expect(first.fetchedAt == now)
    #expect(http.calls.count == 1)
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now.addingTimeInterval(100))
    #expect(http.calls.count == 1) // fresh cache hit, no refetch
}

@Test func manifest_fetchStaleRefetches() async throws {
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now.addingTimeInterval(86_401))
    #expect(http.calls.count == 2)
}

@Test func manifest_fetchTagChangeRefetches() async throws {
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    // OS upgrade changes the bottle tag; a fresh cache for the OLD tag must not be trusted.
    _ = try await fetcher.fetch(bottleTag: "arm64_sequoia", now: now.addingTimeInterval(100))
    #expect(http.calls.count == 2)
}

private final class FakeHTTP: HTTPFetching {
    var calls: [URL] = []
    let response: Data
    init(response: Data) { self.response = response }
    func data(from url: URL) async throws -> Data {
        calls.append(url)
        return response
    }
}

private func makeFetcher() throws -> (ManifestFetcher, FakeHTTP) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = FakeHTTP(response: fixtureData("manifest-mini.json"))
    return (ManifestFetcher(http: fake, cacheURL: dir.appendingPathComponent("manifest-cache.json")), fake)
}
