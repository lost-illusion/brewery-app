import Foundation

private let latestMarker = ":latest"

/// Newest version known from the API manifest for this item, or nil on a
/// manifest miss (tap packages are absent from the core-only manifest).
public func latestVersion(for item: BrewItem, manifest: PackageManifest?) -> String? {
    switch item.kind {
    case .formula: return manifest?.latestFormulaVersion(item.name)
    case .cask:    return manifest?.latestCaskVersion(item.name)
    }
}

/// Brew-default outdated semantics: self-updating casks (auto_updates, or a
/// ":latest" marker on either side) are NOT counted as outdated unless the
/// user opted into greedy mode — then they surface as .selfUpdating.
/// A manifest miss is .unknown, never .upToDate.
public func outdatedState(item: BrewItem, manifest: PackageManifest?, greedy: Bool) -> OutdatedState {
    let installedActive = item.linkedVersion ?? item.installedVersions.last

    if item.kind == .cask {
        let manifestLatest = manifest?.latestCaskVersion(item.name)
        let selfUpdating = item.autoUpdates
            || item.installedVersions.contains(latestMarker)
            || manifestLatest == latestMarker
        if selfUpdating {
            guard greedy else { return .upToDate }
            return .selfUpdating(latestKnown: manifestLatest == latestMarker ? installedActive : manifestLatest)
        }
    }

    guard let latest = latestVersion(for: item, manifest: manifest), latest != latestMarker else {
        return .unknown
    }
    guard let installed = installedActive else { return .unknown }
    if latest == installed || installedIsNewer(installed, than: latest) {
        // installed newer than known latest (API regeneration lag, tap shadowing
        // a core name): brew says up to date — never arrow to an older version.
        return .upToDate
    }
    return .updateAvailable(latest: latest)
}

/// Numeric-segment version compare (dot/underscore separated). False when either
/// side has a non-numeric segment (comparable only where brew itself compares).
private func installedIsNewer(_ installed: String, than latest: String) -> Bool {
    guard let a = numericSegments(installed), let b = numericSegments(latest) else { return false }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

private func numericSegments(_ version: String) -> [Int]? {
    let parts = version.split(whereSeparator: { $0 == "." || $0 == "_" })
    var out: [Int] = []
    for p in parts { guard let n = Int(p) else { return nil }; out.append(n) }
    return out
}
