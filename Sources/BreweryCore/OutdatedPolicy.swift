import Foundation

private let latestMarker = ":latest"

private func manifestLatest(for item: BrewItem, manifest: PackageManifest?) -> String? {
    switch item.kind {
    case .formula: return manifest?.latestFormulaVersion(item.name)
    case .cask:    return manifest?.latestCaskVersion(item.name)
    }
}

/// Newest version known from the API manifest for this item. Tap packages are
/// absent from the core-only manifest, so a miss falls back to the version
/// brew's installed-info reports for the definition itself (§22) — still nil
/// when neither source knows (list-only rows).
public func latestVersion(for item: BrewItem, manifest: PackageManifest?) -> String? {
    manifestLatest(for: item, manifest: manifest) ?? item.infoVersion
}

/// Brew-default outdated semantics: self-updating casks (auto_updates, or a
/// ":latest" marker on either side) are NOT counted as outdated unless the
/// user opted into greedy mode — then they surface as .selfUpdating.
/// A manifest miss is .unknown, never .upToDate.
public func outdatedState(item: BrewItem, manifest: PackageManifest?, greedy: Bool) -> OutdatedState {
    let installedActive = item.linkedVersion ?? item.installedVersions.last
    let manifestHit = manifestLatest(for: item, manifest: manifest)
    let latestKnown = manifestHit ?? item.infoVersion

    if item.kind == .cask {
        let selfUpdating = item.autoUpdates
            || item.installedVersions.contains(latestMarker)
            || latestKnown == latestMarker
        if selfUpdating {
            guard greedy else { return .upToDate }
            return .selfUpdating(latestKnown: latestKnown == latestMarker ? installedActive : latestKnown)
        }
    }

    guard let latest = latestKnown, latest != latestMarker else {
        return .unknown
    }
    guard let installed = installedActive else { return .unknown }
    if latest == installed || installedIsNewer(installed, than: latest) {
        // installed newer than known latest (API regeneration lag, tap shadowing
        // a core name): brew says up to date — never arrow to an older version.
        return .upToDate
    }
    // Manifest miss (tap package): brew's `outdated` boolean is the authority
    // (§22) — a pure version compare against the tap definition the GUI cannot
    // read (`outdated = installed && formula.outdated?` in cmd/info.rb; pinned
    // does not suppress it). Self-updating casks already returned above under
    // the greedy flag.
    if manifestHit == nil, let brewOutdated = item.infoOutdated {
        return brewOutdated ? .updateAvailable(latest: latest) : .upToDate
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
