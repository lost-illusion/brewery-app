import Darwin
import Foundation
import Testing
@testable import BreweryCore

@Test func manifest_decode_miniFixture() throws {
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-mini.json"))
    #expect(manifest.latestFormulaVersion("ace") == "8.0.8")
    #expect(manifest.latestCaskVersion("wireshark-app") == "4.6.9")
    #expect(manifest.latestFormulaVersion("nope") == nil)
    #expect(manifest.latestCaskVersion("nope") == nil)
    // Alias/rename/migration keys are optional: a payload without them decodes
    // with empty values (mini fixture predates them).
    #expect(manifest.formulae["ace"]?.aliases == [])
    #expect(manifest.formulae["ace"]?.oldnames == [])
    #expect(manifest.casks["wireshark-app"]?.names == nil)
    #expect(manifest.formulaRenames == [:])
    #expect(manifest.caskTapMigrations == [:])
}

@Test func manifest_decode_aliasRenameAndMigrationKeys() throws {
    // Live payload shapes (verified 2026-11-12, compat §29).
    let manifest = try PackageManifest.decode(jwsData: fixtureData("manifest-aliases.json"))
    #expect(manifest.formulae["go"]?.aliases == ["golang", "google-go"])
    #expect(manifest.formulae["apptainer"]?.oldnames == ["singularity"])
    #expect(manifest.formulae["lux"]?.aliases == [])
    #expect(manifest.casks["kiro-cli"]?.names == ["Kiro", "Kiro IDE"])
    #expect(manifest.formulaRenames == ["annie": "lux"])
    #expect(manifest.caskRenames == ["amazon-q": "kiro-cli"])
    #expect(manifest.formulaTapMigrations == ["app-engine-go-32": "homebrew/cask/app-engine",
                                              "gtkwave": "homebrew/cask"])
    #expect(manifest.caskTapMigrations == ["chronograf": "homebrew/core"])
}

@Test func manifest_decode_liveWrapper() throws {
    // Live endpoint format (verified 2026-10-30): JWS JSON serialization
    // {"payload":"<manifest JSON string>","signatures":[…]} — NOT a compact dotted JWS.
    let wrapper = #"{"payload":"{\"metadata\":{\"bottle_tag\":\"arm64_golden_gate\"},\"formulae\":{\"ace\":{\"stable_version\":\"8.1.1\"}},\"casks\":{\"wireshark-app\":{\"version\":\"4.7.0\"}}}","signatures":[{"signature":"abc123"}]}"#
    let manifest = try PackageManifest.decode(jwsData: Data(wrapper.utf8))
    #expect(manifest.latestFormulaVersion("ace") == "8.1.1")
    #expect(manifest.latestCaskVersion("wireshark-app") == "4.7.0")
    #expect(manifest.bottleTag == "arm64_golden_gate")
}

@Test func manifest_fetchOfflineServesStaleCache() async throws {
    // Spec Freshness #1: offline → serve the last cached manifest. The plan named
    // this test (fetcher_offlineUsesCache); it was missing from Task 7.
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    http.willThrow = true // Little Snitch / offline / API down
    let offline = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now.addingTimeInterval(86_401))
    #expect(offline.manifest.latestFormulaVersion("ace") == "8.0.8")
    #expect(offline.fetchedAt == now) // the original fetch time, not "now"
}

@Test func manifest_fetchForceRefetchesDespiteFreshCache() async throws {
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now.addingTimeInterval(1), force: true)
    #expect(http.calls.count == 2) // force bypasses the fresh-cache shortcut
}

@Test func manifest_fetchForceFallsBackToCacheOffline() async throws {
    let (fetcher, http) = try makeFetcher()
    let now = Date()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now)
    http.willThrow = true
    let r = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: now.addingTimeInterval(1), force: true)
    #expect(r.manifest.latestFormulaVersion("ace") == "8.0.8")
    #expect(r.fetchedAt == now) // last-good age preserved, not faked to now
}

@Test func manifest_fetchOfflineNoCacheThrows() async throws {
    let (fetcher, http) = try makeFetcher()
    http.willThrow = true
    do {
        _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: Date())
        Issue.record("expected a throw when there is no cache to fall back on")
    } catch is HTTPFailure {}
}

@MainActor
@Test func manifest_fetchRunsOffMainActor() async throws {
    // The manifest payload is ~16 MB; cache I/O + decode must not stall the UI.
    let (fetcher, http) = try makeFetcher()
    _ = try await fetcher.fetch(bottleTag: "arm64_golden_gate", now: Date())
    #expect(!http.sawMainThread.isEmpty)
    #expect(http.sawMainThread.allSatisfy { !$0 })
}

@Test func manifest_decode_licenseAsSPDXObject() throws {
    // Live payload (verified 2026-10-30): 855 of 8686 formulae carry license as an
    // SPDX object — {"GPL-3.0-or-later": {":with": "GCC-exception-3.1"}} or
    // {":all_of": [...]} / {":any_of": [...]} — not a String. Whole decode threw.
    let json = #"{"metadata":{"bottle_tag":"arm64_golden_gate"},"formulae":{"aarch64-elf-gcc":{"stable_version":"15.2.0","license":{"GPL-3.0-or-later":{":with":"GCC-exception-3.1"}}},"abook":{"stable_version":"2.13.2","license":{":all_of":["GPL-3.0-only","BSD-2-Clause"]}}},"casks":{}}"#
    let m = try PackageManifest.decode(jwsData: Data(json.utf8))
    // Normalized: license identifiers flattened, sorted unique, comma-joined.
    #expect(m.formulae["aarch64-elf-gcc"]?.license == "GCC-exception-3.1, GPL-3.0-or-later")
    #expect(m.formulae["abook"]?.license == "BSD-2-Clause, GPL-3.0-only")
}

@Test func manifest_liveHTTPRequestTimeout() {
    // The manifest is ~16 MB; URLSession's 60 s default timed out on a live fetch (2026-10-30).
    let request = LiveHTTP.request(url: ManifestFetcher.endpointURL(bottleTag: "arm64_golden_gate"))
    #expect(request.timeoutInterval >= 120)
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

private struct HTTPFailure: Error {}

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    var calls: [URL] = []
    var willThrow = false
    var sawMainThread: [Bool] = []
    let response: Data
    init(response: Data) { self.response = response }
    func data(from url: URL) async throws -> Data {
        calls.append(url)
        sawMainThread.append(pthread_main_np() != 0) // Thread.isMainThread is banned in async contexts
        if willThrow { throw HTTPFailure() }
        return response
    }
}

private func makeFetcher() throws -> (ManifestFetcher, FakeHTTP) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = FakeHTTP(response: fixtureData("manifest-mini.json"))
    return (ManifestFetcher(http: fake, cacheURL: dir.appendingPathComponent("manifest-cache.json")), fake)
}
