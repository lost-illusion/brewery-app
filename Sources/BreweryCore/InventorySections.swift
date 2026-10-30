import Foundation

public enum Section: String, CaseIterable {
    case all, formulae, casks, outdated, pinned, deprecated, taps
}

/// Local filtering only — never re-queries brew (spec Goal 5).
public func items(_ items: [BrewItem], in section: Section, query: String?, greedy: Bool) -> [BrewItem] {
    items.filter { matchesSection($0, section, greedy: greedy) && matchesQuery($0, query) }
}

public func sidebarCounts(_ items: [BrewItem], greedy: Bool) -> [Section: Int] {
    Section.allCases.reduce(into: [Section: Int]()) { counts, section in
        counts[section] = items.filter { matchesSection($0, section, greedy: greedy) }.count
    }
}

private func matchesSection(_ item: BrewItem, _ section: Section, greedy: Bool) -> Bool {
    switch section {
    case .all: true
    case .formulae: item.kind == .formula
    case .casks: item.kind == .cask
    case .outdated:
        switch item.outdated {
        case .updateAvailable: true
        case .selfUpdating: greedy // brew-default hides self-updating casks
        default: false           // .unknown and .upToDate are never "outdated"
        }
    case .pinned: item.isPinned
    case .deprecated: item.isDeprecated
    case .taps: false // sidebar pane with its own list; no inventory row belongs to it
    }
}

private func matchesQuery(_ item: BrewItem, _ query: String?) -> Bool {
    guard let query, !query.isEmpty else { return true }
    if item.name.localizedCaseInsensitiveContains(query) { return true }
    if let desc = item.desc, desc.localizedCaseInsensitiveContains(query) { return true }
    return false
}
