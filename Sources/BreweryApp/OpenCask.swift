import AppKit
import BreweryCore

/// Gate for every launch affordance (Open button, row double-click, context
/// menu): installed casks with at least one `.app` artifact target. Binary-
/// only or pkg-only casks (revmux) have nothing GUI to launch — no affordance
/// is honest, not missing UI (§88).
func openableCask(_ item: BrewItem) -> Bool {
    item.kind == .cask && !item.installedVersions.isEmpty && !item.appTargets.isEmpty
}

/// Launch every `.app` target of a cask through LaunchServices. The paths come
/// from the info JSON the inventory already fetched, so no brew process runs.
/// false = nothing opened: the app was moved or deleted since the inventory
/// read, or its target no longer exists.
@MainActor @discardableResult
func openCaskApps(_ item: BrewItem) -> Bool {
    var opened = false
    for path in item.appTargets where NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
        opened = true
    }
    return opened
}
