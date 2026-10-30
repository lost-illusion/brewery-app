import Foundation

/// Merges `brew list --json --versions` with `brew info --json=v2 --installed`
/// into display rows. list is the row authority (what is actually installed);
/// info supplies metadata. Rows only in one side survive with a sourceState
/// that says so — compatibilities §43 (untrusted taps omit info), §47 (casks key on token).
public struct InventoryMerger {
    static let listOnlyReason = "no source info — untrusted tap or API skew"

    // Homebrew's own precedence (DeprecateDisable.message): when disabled, the
    // disable replacement pair wins; otherwise the deprecation pair.
    static func formulaReplacements(_ fi: InfoSnapshot.FormulaInfo?) -> (formula: String?, cask: String?) {
        guard let fi else { return (nil, nil) }
        return fi.disabled
            ? (fi.disableReplacementFormula, fi.disableReplacementCask)
            : (fi.deprecationReplacementFormula, fi.deprecationReplacementCask)
    }

    static func caskReplacements(_ ci: InfoSnapshot.CaskInfo?) -> (formula: String?, cask: String?) {
        guard let ci else { return (nil, nil) }
        return ci.disabled
            ? (ci.disableReplacementFormula, ci.disableReplacementCask)
            : (ci.deprecationReplacementFormula, ci.deprecationReplacementCask)
    }

    public static func merge(list: ListSnapshot, info: InfoSnapshot) -> [BrewItem] {
        let infoFormulae = Dictionary(info.formulae.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let infoCasks = Dictionary(info.casks.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [BrewItem] = []
        var matchedFormulaNames = Set<String>()
        var matchedCaskTokens = Set<String>()

        for f in list.formulae {
            let fi = infoFormulae[f.name]
            if fi != nil { matchedFormulaNames.insert(f.name) }
            let reps = formulaReplacements(fi)
            items.append(BrewItem(
                id: fi?.fullName ?? f.name,
                kind: .formula,
                name: f.name,
                fullName: fi?.fullName ?? f.name,
                tap: fi?.tap,
                installedVersions: f.versions,
                linkedVersion: f.linkedVersion,
                optlinkedVersion: f.optlinkedVersion,
                pinnedVersion: f.pinnedVersion,
                latestVersion: nil,    // Task 8 fills these
                outdated: nil,
                isPinned: fi?.pinned ?? false,
                isDeprecated: fi?.deprecated ?? false,
                deprecationReason: fi?.deprecationReason,
                isDisabled: fi?.disabled ?? false,
                disabledReason: fi?.disabledReason,
                deprecationDate: fi?.deprecationDate,
                disableDate: fi?.disableDate,
                replacementFormula: reps.formula,
                replacementCask: reps.cask,
                desc: fi?.desc,
                homepage: fi?.homepage,
                installedAt: fi?.installed.first?.time,
                kegOnly: fi?.kegOnly ?? false,
                autoUpdates: false,
                dependencies: fi?.dependencies ?? [],
                sourceState: fi != nil ? .complete : .listOnly(reason: listOnlyReason)
            ))
        }

        for c in list.casks {
            let ci = infoCasks[c.token]
            if ci != nil { matchedCaskTokens.insert(c.token) }
            let reps = caskReplacements(ci)
            items.append(BrewItem(
                id: c.token,
                kind: .cask,
                name: c.token,
                fullName: c.token,
                tap: ci?.tap,
                installedVersions: c.versions,
                linkedVersion: nil, // casks have no keg/link concept
                optlinkedVersion: nil,
                pinnedVersion: c.pinnedVersion,
                latestVersion: nil,
                outdated: nil,
                isPinned: (ci?.pinned ?? false) || c.pinnedVersion != nil,
                isDeprecated: ci?.deprecated ?? false,
                deprecationReason: ci?.deprecationReason,
                isDisabled: ci?.disabled ?? false,
                disabledReason: ci?.disabledReason,
                deprecationDate: ci?.deprecationDate,
                disableDate: ci?.disableDate,
                replacementFormula: reps.formula,
                replacementCask: reps.cask,
                desc: ci?.desc,
                homepage: ci?.homepage,
                installedAt: ci?.installedTime,
                kegOnly: false,
                autoUpdates: ci?.autoUpdates ?? false,
                dependencies: (ci?.dependsFormula ?? []) + (ci?.dependsCask ?? []),
                sourceState: ci != nil ? .complete : .listOnly(reason: listOnlyReason)
            ))
        }

        // Reverse skew: info rows with no list row (info reported installed, list disagrees).
        for fi in info.formulae where !matchedFormulaNames.contains(fi.name) {
            items.append(BrewItem(
                id: fi.fullName,
                kind: .formula,
                name: fi.name,
                fullName: fi.fullName,
                tap: fi.tap,
                installedVersions: fi.installed.map(\.version),
                linkedVersion: fi.linkedKeg,
                optlinkedVersion: nil,
                pinnedVersion: nil,
                latestVersion: nil,
                outdated: nil,
                isPinned: fi.pinned,
                isDeprecated: fi.deprecated,
                deprecationReason: fi.deprecationReason,
                isDisabled: fi.disabled,
                disabledReason: fi.disabledReason,
                deprecationDate: fi.deprecationDate,
                disableDate: fi.disableDate,
                replacementFormula: formulaReplacements(fi).formula,
                replacementCask: formulaReplacements(fi).cask,
                desc: fi.desc,
                homepage: fi.homepage,
                installedAt: fi.installed.first?.time,
                kegOnly: fi.kegOnly,
                autoUpdates: false,
                dependencies: fi.dependencies,
                sourceState: .infoOnly
            ))
        }
        for ci in info.casks where !matchedCaskTokens.contains(ci.token) {
            items.append(BrewItem(
                id: ci.token,
                kind: .cask,
                name: ci.token,
                fullName: ci.token,
                tap: ci.tap,
                installedVersions: ci.installedVersion.map { [$0] } ?? [],
                linkedVersion: nil,
                optlinkedVersion: nil,
                pinnedVersion: nil,
                latestVersion: nil,
                outdated: nil,
                isPinned: ci.pinned,
                isDeprecated: ci.deprecated,
                deprecationReason: ci.deprecationReason,
                isDisabled: ci.disabled,
                disabledReason: ci.disabledReason,
                deprecationDate: ci.deprecationDate,
                disableDate: ci.disableDate,
                replacementFormula: caskReplacements(ci).formula,
                replacementCask: caskReplacements(ci).cask,
                desc: ci.desc,
                homepage: ci.homepage,
                installedAt: ci.installedTime,
                kegOnly: false,
                autoUpdates: ci.autoUpdates,
                dependencies: ci.dependsFormula + ci.dependsCask,
                sourceState: .infoOnly
            ))
        }

        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return items
    }
}
