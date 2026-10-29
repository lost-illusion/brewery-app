import Foundation

public func discoverBrew(searchPaths: [String], pathOverride: String?) -> URL? {
    let fm = FileManager.default
    if let override = pathOverride, !override.isEmpty {
        let url = URL(fileURLWithPath: override)
        return fm.isExecutableFile(atPath: url.path) ? url : nil
    }
    for path in searchPaths where fm.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return nil
}
