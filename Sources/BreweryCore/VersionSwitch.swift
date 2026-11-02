import Foundation

// MARK: - Version switching (compat §27)
//
// Homebrew 7.0.11 removed `brew switch`/`brew versions`; versioned names resolve
// only against tap definitions that exist (`brew info wget@1.21.1` live-errors
// "No available formula with the name"), so a switch is:
//   already installed → relink the keg (`brew unlink` the linked kegs, `brew link` the target rack), or
//   not installed     → `brew extract --version=V <name> <tap>` materializes `<name>@V.rb`,
//                       then a qualified `-y` install; the old keg stays installed but unlinked
//                       (the switch back is then the relink path).
// keg commands resolve names to Cellar racks (`cli/named_args.rb` `resolve_kegs`):
// a versioned install lives at `Cellar/<name>@<version>/`, so `brew link/unlink <name>@<version>`
// addresses that keg without any tap definition. Casks have no versioned installs —
// `brew info --cask iterm2@3.4.0` live-errors "No Cask with this name exists", and extract
// is formula-only — so casks never get a switch plan.

// MARK: - Name helpers

/// The product name a keg family is keyed on — mirrors extract's own
/// `name.sub(/\b@.*\z\b/i, "")` (`dev-cmd/extract.rb`): strips the trailing
/// `@…` suffix, so `wget@1.21.1`, `openssl@3` and `wget` share family `wget`.
public func baseFormulaName(_ name: String) -> String {
    guard let at = name.lastIndex(of: "@") else { return name }
    return String(name[..<at])
}

/// extract sanitizes the version it puts into the destination file name with
/// Ruby `sub(/\D*(.+?)\D*$/, "\\1").gsub(/\D+/, ".")` — strip leading/trailing
/// non-digits, collapse every other non-digit run to a dot. Replicated so the
/// GUI can name the expected keg even when extract's stdout lacks the path line.
public func sanitizedExtractVersion(_ version: String) -> String {
    var body = Substring(version)
    while let c = body.first, !c.isNumber { body = body.dropFirst() }
    while let c = body.last, !c.isNumber { body = body.dropLast() }
    var out = ""
    var inRun = false
    for c in body {
        if c.isNumber { out.append(c); inRun = false }
        else if !inRun { out.append("."); inRun = true }
    }
    return out
}

/// The formula name extract will write (`Formula/<base>@<sanitized>.rb`).
/// Qualified inputs are unqualified first — extract resolves `user/repo/formula`
/// through `Tap.with_formula_name` and names the file after the bare formula.
public func versionedFormulaName(baseName: String, version: String) -> String {
    let bare = baseFormulaName(baseName.split(separator: "/").last.map(String.init) ?? baseName)
    return "\(bare)@\(sanitizedExtractVersion(version))"
}

/// The name of the formula extract just wrote. `ohai "… to:", path` puts the
/// destination path on the last line ending `.rb` (patch copies print further
/// lines, but they end `.patch`/`.rb` too — the *formula* line is the one
/// ending `@<version>.rb` under a `Formula/` directory). Falls back to the
/// name the GUI computed for the same `--version`.
public func extractedFormulaName(from stdout: Data, fallbackBase: String, fallbackVersion: String) -> String {
    let lines = String(decoding: stdout, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    // Patch copies also print paths, but extracted formulae are the only `.rb`
    // paths with a `@` (patches are `.patch`).
    if let path = lines.last(where: { $0.hasSuffix(".rb") && $0.contains("@") }),
       let file = path.split(separator: "/").last, file.hasSuffix(".rb") {
        return String(file.dropLast(3))
    }
    return versionedFormulaName(baseName: fallbackBase, version: fallbackVersion)
}

// MARK: - Plan

/// What a "switch to <version>" click will run. GUI shows the copy verbatim
/// in the confirm sheet before the user commits (mutating — compat §27).
public enum VersionSwitchPlan: Equatable {
    /// Target keg already installed: relink it. `unlinkRacks` are the family's
    /// currently linked kegs whose symlinks would collide with the target.
    case relink(linkRack: String, unlinkRacks: [String], kegOnly: Bool)
    /// Target keg missing: clone the source tap if it isn't on disk, extract
    /// `--force` into a destination tap, unlink the currently linked family
    /// kegs, install the extracted formula qualified with `-y`.
    case extractInstall(sourceName: String, version: String, sourceTap: String,
                        destinationCandidates: [String], needsSourceTapClone: Bool)
    /// No switch for this row — the reason is display text.
    case blocked(reason: String)

    public var isActionable: Bool {
        switch self {
        case .relink, .extractInstall: return true
        case .blocked: return false
        }
    }
}

/// Family = formula items of the same product (`wget`, `wget@1.21.1`, …). Used
/// to find the target keg and the linked kegs an install/switch must unlink.
public func versionFamily(of item: BrewItem, in items: [BrewItem]) -> [BrewItem] {
    guard item.kind == .formula else { return [] }
    let base = baseFormulaName(item.name)
    return items.filter { $0.kind == .formula && baseFormulaName($0.name) == base }
}

public func versionSwitchPlan(for item: BrewItem, to version: String,
                              items: [BrewItem], taps: [TapInfo]) -> VersionSwitchPlan {
    guard item.kind == .formula else {
        return .blocked(reason: "brew has no versioned casks — a cask install always takes the current version (compat §27).")
    }

    let family = versionFamily(of: item, in: items)

    // Target keg installed as a single-version keg → relink. A multi-version
    // legacy keg (Cellar/<name> holding two kegs) can't be pinned by `brew
    // link` (it resolves `latest_kegs`, `cmd/link.rb`), so those fall through
    // to the extract path, which installs the target as its own rack.
    if let keg = family.first(where: { $0.installedVersions.contains(version) }),
       keg.installedVersions.count == 1 {
        if keg.linkedVersion == version {
            return .blocked(reason: "\(version) is already the linked version.")
        }
        let unlinkRacks = family
            .filter { $0.fullName != keg.fullName && $0.linkedVersion != nil }
            .map(\.fullName)
        return .relink(linkRack: keg.fullName, unlinkRacks: unlinkRacks, kegOnly: keg.kegOnly)
    }

    // Source tap for extract: bare name for core/unknown (extract defaults to
    // homebrew/core), fully-qualified for third-party taps (its own usage text).
    let sourceTap = item.tap ?? "homebrew/core"
    let isCore = sourceTap.lowercased() == "homebrew/core"
    let sourceName = isCore ? item.name : item.fullName

    let coreTap = taps.first { $0.name.lowercased() == "homebrew/core" }
    var needsClone = false
    if isCore {
        // API-mode machines have no homebrew/core clone; extract's
        // `source_tap.installed?` gate (`Tap#installed?` = `path.directory?`) fails without it.
        needsClone = !(coreTap?.installed ?? false)
    } else {
        guard let info = taps.first(where: { $0.name.lowercased() == sourceTap.lowercased() }) else {
            return .blocked(reason: "Tap \(sourceTap) is not in the tap list — open the Taps pane, then retry.")
        }
        guard info.installed else {
            return .blocked(reason: "Tap \(sourceTap) is not cloned on disk — brew extract reads its git history.")
        }
    }

    // Destination: brew odies homebrew/core, homebrew/cask and the source tap itself
    // (`dev-cmd/extract.rb`, non-developer) — GUI offers only installed user taps.
    let candidates = taps
        .filter { $0.installed }
        .map(\.name)
        .filter {
            let n = $0.lowercased()
            return n != "homebrew/core" && n != "homebrew/cask" && n != sourceTap.lowercased()
        }
    if candidates.isEmpty {
        return .blocked(reason: "No tap to extract into: brew refuses homebrew/core, homebrew/cask, and the source tap as destinations — add a tap in the Taps pane first.")
    }

    return .extractInstall(sourceName: sourceName, version: version, sourceTap: sourceTap,
                           destinationCandidates: candidates, needsSourceTapClone: needsClone)
}
