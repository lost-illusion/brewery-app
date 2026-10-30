import Foundation

/// Direct dependents computed locally by inverting `dependencies` across the
/// inventory — compatibilities §2: `brew uses` has no JSON; §63 prescribes this
/// inversion. Direct only (transitive would be `brew uses --recursive`).
public struct ReverseDependencies {
    private let dependentsByID: [String: [BrewItem]]

    public init(items: [BrewItem]) {
        // Dep strings resolve exactly like the detail-page chips: item id
        // (fullName / cask token) wins, then a bare name as fallback.
        var resolvedID: [String: String] = [:]
        for it in items { resolvedID[it.id] = it.id }
        for it in items where resolvedID[it.name] == nil { resolvedID[it.name] = it.id }

        var reverse: [String: [String]] = [:] // target id → dependent ids, inventory order
        for it in items {
            for dep in it.dependencies {
                guard let targetID = resolvedID[dep], targetID != it.id else { continue }
                guard !reverse[targetID, default: []].contains(it.id) else { continue }
                reverse[targetID, default: []].append(it.id)
            }
        }

        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        dependentsByID = reverse.mapValues { ids in ids.compactMap { byID[$0] } }
    }

    public func dependents(of item: BrewItem) -> [BrewItem] { dependentsByID[item.id] ?? [] }
}
