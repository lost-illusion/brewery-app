import Foundation

/// Keeps the newest raw output of each brew invocation so the app can show
/// data while a refresh is in flight and label it with its age.
public final class SnapshotStore {
    public enum Kind: String { case listJSON, infoJSON, textList }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func fileURL(_ kind: Kind) -> URL {
        directory.appendingPathComponent("snapshot.\(kind.rawValue)")
    }

    public func save(_ data: Data, kind: Kind) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(kind), options: .atomic)
    }

    /// Newest snapshot for the kind, with its file mtime as savedAt; nil if absent.
    public func loadLatest(_ kind: Kind) -> (data: Data, savedAt: Date)? {
        let url = fileURL(kind)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let savedAt = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (data, savedAt)
    }
}
