import Foundation

public enum Section: String, CaseIterable {
    // Declaration order is the sidebar row order (Sidebar iterates allCases).
    // topInstalls leads; raw values stay stable if the order changes again.
    // .formulae/.casks sidebar rows are retired — kind is an Installed-pane
    // filter (KindFilter), not a sidebar section. install is the search-and-
    // install catalog pane (design 2026-11-02), slotted after Installed.
    case topInstalls, all, install, outdated, pinned, deprecated, taps
}

/// The Installed pane's kind segment (All | Formulae | Casks). Separate from
/// Section on purpose: it composes with the section + search instead of being
/// a navigable pane of its own.
public enum KindFilter: String, CaseIterable {
    case all, formulae, casks

    public var title: String {
        switch self {
        case .all: "All"
        case .formulae: "Formulae"
        case .casks: "Casks"
        }
    }
}

public func items(_ items: [BrewItem], kind: KindFilter) -> [BrewItem] {
    switch kind {
    case .all: items
    case .formulae: items.filter { $0.kind == .formula }
    case .casks: items.filter { $0.kind == .cask }
    }
}

/// Local filtering only — never re-queries brew (spec Goal 5).
public func items(_ items: [BrewItem], in section: Section, query: String?, greedy: Bool) -> [BrewItem] {
    items.filter { matchesSection($0, section, greedy: greedy) && matchesQuery($0, query) }
}

/// Whether the row the given id selects is visible in the given pane's list —
/// same filters the content column applies (section rule, query, and the
/// Installed-pane kind segment). The detail column may only show a visible row:
/// a selection made under a previous filter/pane is stale once the filter moves
/// (2026-11-02: sidebar on an empty Outdated pane, right pane still showing the
/// cask selected in Installed moments earlier).
public func isVisible(_ inventory: [BrewItem], selectedID: String?, in section: Section,
                      query: String?, kind: KindFilter, greedy: Bool) -> Bool {
    guard let selectedID else { return true } // nothing selected — nothing stale
    // Kind is the Installed pane's segment only (PackageList applies it there);
    // the other panes' section rule already decides membership.
    let rows = items(inventory, in: section, query: query, greedy: greedy)
    return items(rows, kind: section == .all ? kind : .all).contains { $0.id == selectedID }
}

public func sidebarCounts(_ items: [BrewItem], greedy: Bool) -> [Section: Int] {
    Section.allCases.reduce(into: [Section: Int]()) { counts, section in
        counts[section] = items.filter { matchesSection($0, section, greedy: greedy) }.count
    }
}

private func matchesSection(_ item: BrewItem, _ section: Section, greedy: Bool) -> Bool {
    switch section {
    case .all: true
    case .outdated:
        switch item.outdated {
        case .updateAvailable: true
        case .selfUpdating: greedy // brew-default hides self-updating casks
        default: false           // .unknown and .upToDate are never "outdated"
        }
    case .pinned: item.isPinned
    case .deprecated: item.isDeprecated
    case .taps, .topInstalls, .install: false // sidebar panes with their own lists; no inventory row belongs to them
    }
}

private func matchesQuery(_ item: BrewItem, _ query: String?) -> Bool {
    guard let query, !query.isEmpty else { return true }
    if item.name.localizedCaseInsensitiveContains(query) { return true }
    if let desc = item.desc, desc.localizedCaseInsensitiveContains(query) { return true }
    return false
}
