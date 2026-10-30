import Foundation

/// Linear trail of selected package IDs behind the detail pane's back/forward
/// buttons. Link-follow semantics: a new selection truncates any forward
/// branch; selecting the current page is a no-op, so programmatic back/forward
/// write-backs to the selection never duplicate entries.
public struct NavigationHistory {
    private(set) public var entries: [String] = []
    private(set) public var index: Int = -1

    public init() {}

    public var current: String? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < entries.count }

    public mutating func select(_ id: String) {
        guard current != id else { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(id)
        index = entries.count - 1
    }

    @discardableResult public mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    @discardableResult public mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}
