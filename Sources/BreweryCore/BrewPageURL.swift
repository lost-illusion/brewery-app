import Foundation

/// Homebrew's own page for an installed package (compatibilities §23:
/// third-party tap packages have no formulae.brew.sh entry — their brew page
/// is the tap's GitHub repo). nil when the tap is unknown (text-list rows).
public func brewPageURL(for item: BrewItem) -> URL? {
    guard let tap = item.tap else { return nil }
    let lower = tap.lowercased()

    switch (item.kind, lower) {
    case (.formula, "homebrew/core"):
        return URL(string: "https://formulae.brew.sh/formula/\(item.name)")
    case (.cask, "homebrew/core"), (.cask, "homebrew/cask"):
        return URL(string: "https://formulae.brew.sh/cask/\(item.name)")
    default:
        // Tap repos follow the homebrew-<name> naming convention on GitHub.
        let parts = tap.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let owner = lower.hasPrefix("homebrew/") ? "Homebrew" : String(parts[0])
        let repo = parts[1].lowercased().hasPrefix("homebrew-")
            ? String(parts[1]) : "homebrew-\(parts[1])"
        return URL(string: "https://github.com/\(owner)/\(repo)")
    }
}
