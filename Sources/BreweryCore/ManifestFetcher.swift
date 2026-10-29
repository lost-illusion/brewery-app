import Foundation

public protocol HTTPFetching {
    func data(from url: URL) async throws -> Data
}

public struct LiveHTTP: HTTPFetching {
    public init() {}
    public func data(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

public struct ManifestFetchResult {
    public let manifest: PackageManifest
    public let fetchedAt: Date
}

/// Read-only fetch of the formulae.brew.sh package manifest, with a local
/// cache so the app never needs `brew update` (design doc §Freshness).
public struct ManifestFetcher {
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
    public func fetch(bottleTag: String, now: Date) async throws -> ManifestFetchResult {
        if let cached = readCache(),
           !Self.isStale(fetchedAt: cached.fetchedAt, now: now),
           cached.manifest.bottleTag == bottleTag {
            return cached
        }
        let data = try await http.data(from: Self.endpointURL(bottleTag: bottleTag))
        let manifest = try PackageManifest.decode(jwsData: data)
        let result = ManifestFetchResult(manifest: manifest, fetchedAt: now)
        writeCache(result, jws: data)
        return result
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
