import Foundation

public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct LiveHTTP: HTTPFetching {
    public init() {}

    /// ~16 MB payload: the 60 s URLSession default timed out on a live fetch (2026-10-30).
    public static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        return request
    }

    public func data(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(for: Self.request(url: url))
        return data
    }
}

public struct ManifestFetchResult {
    public let manifest: PackageManifest
    public let fetchedAt: Date
}

/// Read-only fetch of the formulae.brew.sh package manifest, with a local
/// cache so the app never needs `brew update` (design doc §Freshness).
public struct ManifestFetcher: Sendable {
    public let http: HTTPFetching
    public let cacheURL: URL

    public init(http: HTTPFetching = LiveHTTP(), cacheURL: URL = ManifestFetcher.defaultCacheURL()) {
        self.http = http
        self.cacheURL = cacheURL
    }

    public static func endpointURL(bottleTag: String) -> URL {
        // /api/packages.<tag>.jws.json 404s — the live path is /api/internal/ (compatibilities §23)
        URL(string: "https://formulae.brew.sh/api/internal/packages.\(bottleTag).jws.json")!
    }

    public static func isStale(fetchedAt: Date, now: Date, threshold: TimeInterval = 86_400) -> Bool {
        now.timeIntervalSince(fetchedAt) > threshold
    }

    public static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brewery", isDirectory: true)
            .appendingPathComponent("manifest-cache.json")
    }

    /// Returns the cached manifest when it is fresh for this bottle tag;
    /// otherwise downloads, decodes, writes the cache, and returns fetchedAt = now.
    /// `force: true` bypasses the fresh-cache shortcut (a manual "fetch now");
    /// the offline fallback still serves the last-good cache if the download fails.
    public func fetch(bottleTag: String, now: Date, force: Bool = false) async throws -> ManifestFetchResult {
        let cached = readCache()
        if !force, let cached,
           !Self.isStale(fetchedAt: cached.fetchedAt, now: now),
           cached.manifest.bottleTag == bottleTag {
            return cached
        }
        do {
            let data = try await http.data(from: Self.endpointURL(bottleTag: bottleTag))
            let manifest = try PackageManifest.decode(jwsData: data)
            let result = ManifestFetchResult(manifest: manifest, fetchedAt: now)
            writeCache(result, jws: data)
            return result
        } catch {
            // Offline / API failure: a stale last-good manifest beats no manifest at all
            // (spec Freshness #1: "Offline: serve the last cached manifest").
            if let cached, cached.manifest.bottleTag == bottleTag { return cached }
            throw error
        }
    }

    private struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let jws: Data
    }

    private func readCache() -> ManifestFetchResult? {
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              let manifest = try? PackageManifest.decode(jwsData: envelope.jws)
        else { return nil }
        return ManifestFetchResult(manifest: manifest, fetchedAt: envelope.fetchedAt)
    }

    private func writeCache(_ result: ManifestFetchResult, jws: Data) {
        let envelope = CacheEnvelope(fetchedAt: result.fetchedAt, jws: jws)
        guard let encoded = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? encoded.write(to: cacheURL, options: .atomic)
    }
}
