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
    return latest == installed ? .upToDate : .updateAvailable(latest: latest)
}
