import AppKit
import BreweryCore
import SwiftUI

struct PackageDetail: View {
    let item: BrewItem?
    let allItems: [BrewItem]
    let model: InventoryModel
    let bottleTag: String?
    let openPackage: (String) -> Void

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(item)
                    if case .failed(let message) = model.upgrade {
                        Label(message, systemImage: "exclamationmark.octagon.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.red.opacity(0.12))
                            .textSelection(.enabled)
                    }
                    if let notice = DeprecationNotice(item) {
                        DeprecationBanner(notice: notice)
                    }
                    if let desc = item.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if case .listOnly(let reason) = item.sourceState {
                        Label(reason, systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    facts(item)
                    if !item.dependencies.isEmpty {
                        GroupBox("Dependencies") {
                            FlowLayout(spacing: 6) {
                                ForEach(item.dependencies, id: \.self) { dep in
                                    dependencyChip(dep)
                                }
                            }
                        }
                    }
                    let usedBy = ReverseDependencies(items: allItems).dependents(of: item)
                    if !usedBy.isEmpty {
                        GroupBox("Used by (\(usedBy.count))") {
                            FlowLayout(spacing: 6) {
                                ForEach(usedBy, id: \.id) { dependent in
                                    dependentChip(dependent)
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        if let homepage = item.homepage, let url = URL(string: homepage) {
                            Button("Open homepage") { NSWorkspace.shared.open(url) }
                        }
                        if let brewPage = brewPageURL(for: item) {
                            Button("Open brew page") { NSWorkspace.shared.open(brewPage) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 560, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a package", systemImage: "sidebar.right",
                                   description: Text("Pick a row to see tap, versions, and dependencies."))
        }
    }

    /// Installed deps are links into the inventory; the rest stay as inert
    /// chips (a dependency of an installed formula is normally installed, so
    /// the inert case means the dep row went missing from the inventory).
    @ViewBuilder private func dependencyChip(_ dep: String) -> some View {
        if let target = installedItem(for: dep) {
            Button(dep) { openPackage(target.id) }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .help("Open \(dep)")
        } else {
            Text(dep)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .help("not installed — no page in this inventory")
        }
    }

    /// Info JSON lists deps by name (tap-qualified full names for third-party
    /// taps). itemIndex keys items by id first, then bare name as fallback.
    private func installedItem(for dep: String) -> BrewItem? { itemIndex[dep] }

    /// Dependents are inventory members by construction (the reverse index is
    /// built from this same item list), so every chip is a live link.
    private func dependentChip(_ dependent: BrewItem) -> some View {
        Button(chipLabel(dependent)) { openPackage(dependent.id) }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .help("Open \(dependent.fullName)")
    }

    /// Mirror the forward chips: bare name for core taps, full name when a
    /// third-party tap is what distinguishes the package.
    private func chipLabel(_ item: BrewItem) -> String {
        switch item.tap {
        case nil, "homebrew/core", "homebrew/cask": return item.name
        default: return item.fullName
        }
    }

    private var itemIndex: [String: BrewItem] {
        var index: [String: BrewItem] = [:]
        for it in allItems { index[it.id] = it }
        for it in allItems { if index[it.name] == nil { index[it.name] = it } }
        return index
    }

    private func header(_ item: BrewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.fullName).font(.title2.bold())
            HStack(spacing: 6) {
                Text(item.kind == .formula ? "Formula" : "Cask").font(.callout)
                outdatedBadge(item)
                Spacer()
                updateButton(item)
            }
        }
    }

    /// Only outdated pages get an Update action; the badge row stays uncluttered
    /// for up-to-date/unknown packages. .selfUpdating only surfaces under the
    /// greedy setting, and the model adds --greedy to the command for it (§70).
    @ViewBuilder private func updateButton(_ item: BrewItem) -> some View {
        switch item.outdated {
        case .updateAvailable, .selfUpdating:
            Button {
                Task { await model.upgrade(item) }
            } label: {
                Label("Update", systemImage: "arrow.down.circle")
                    .opacity(model.upgrade == .idle ? 1 : 0)
                    .overlay {
                        if model.upgrade != .idle {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
            .buttonStyle(.borderedProminent)
            .disabled(item.isPinned || model.state == .loading || model.upgrade != .idle)
            .help(item.isPinned
                  ? "pinned — brew upgrade skips pinned packages"
                  : "brew update, then brew upgrade \(item.name)")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func outdatedBadge(_ item: BrewItem) -> some View {
        switch item.outdated {
        case .updateAvailable(let latest):
            Text("update → \(latest)").font(.caption.bold()).foregroundStyle(.tint)
        case .upToDate:
            Text("up to date").font(.caption).foregroundStyle(.green)
        case .selfUpdating:
            Text("self-updating").font(.caption).foregroundStyle(.secondary)
        case nil, .some(.unknown):
            Text("version unknown").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func facts(_ item: BrewItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let tap = item.tap { row("Tap", tap) }
            row("Installed", item.installedVersions.joined(separator: ", "))
            if let linked = item.linkedVersion { row("Linked keg", linked) }
            if item.kegOnly { row("Keg-only", "yes") }
            if item.isPinned { row("Pinned", item.pinnedVersion ?? "yes") }
            if let installedAt = item.installedAt {
                row("Installed at", installedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if item.kind == .cask, item.autoUpdates { row("Auto-updates", "yes") }
            if let latest = item.latestVersion { row("Latest known", latest) }
            if let bottleTag { row("Bottle tag", bottleTag) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Wraps subviews into left-aligned rows of chips at the proposed width.
/// Dependency counts are small, so subview sizing is recomputed per pass
/// rather than cached.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.reduce(0) { max($0, $1.width) }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let sub = subviews[i]
                let size = sub.sizeThatFits(.unspecified)
                sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            if !row.indices.isEmpty { row.width += spacing }
            row.indices.append(i)
            row.width += size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Site-parity banner: formulae.brew.sh prefixes disabled headings with a red
/// ⛔ and deprecated ones with a ⚠; wording mirrors the site's heading title.
private struct DeprecationBanner: View {
    let notice: DeprecationNotice

    private var isDisabled: Bool { notice.status == .disabled }
    private var tint: Color { isDisabled ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isDisabled ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.text)
                if let command = notice.replacementCommand {
                    Text("Replacement: \(command)")
                        .font(.callout)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.12))
        .textSelection(.enabled)
    }
}
