import AppKit
import BreweryCore
import SwiftUI

struct PackageDetail: View {
    let item: BrewItem?
    let allItems: [BrewItem]
    let model: InventoryModel
    let bottleTag: String?
    let openPackage: (String) -> Void

    @Environment(AppState.self) private var app
    @AppStorage(AppState.changelogSourceKey) private var changelogSource: ChangelogSource = .off
    @State private var showAllCommits = false
    @State private var visibleCommits = 10

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
                    if changelogSource != .off {
                        // One merged list: packaging bumps carry their upstream
                        // release's title/pre-release chip; releases with no
                        // matching bump appear as "not packaged" rows.
                        versionHistorySection(item)
                    }
                    HStack(spacing: 10) {
                        if let homepage = item.homepage, let url = URL(string: homepage) {
                            Button("Open homepage") { NSWorkspace.shared.open(url) }
                        }
                        // Best-effort (§21): homepage is a github.com repo → its
                        // releases page; non-GitHub upstreams keep the homepage link.
                        if let notes = releaseNotesURL(for: item) {
                            Button("Release notes") { NSWorkspace.shared.open(notes) }
                        }
                        if let brewPage = brewPageURL(for: item) {
                            Button("Open brew page") { NSWorkspace.shared.open(brewPage) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 560, alignment: .leading)
                // Combined key: re-fires on package switch and on a settings
                // flip while the same package stays selected.
                .task(id: "\(item.id)|\(changelogSource.rawValue)") {
                    guard changelogSource != .off else { return }
                    // Tap routes need the lazily loaded tap list before routing.
                    if historyRouteNeedsTaps(for: item), model.tapsState != .ready {
                        await model.loadTaps()
                    }
                    await app.versionHistory.load(for: item, taps: model.taps)
                    await app.versionHistory.loadReleases(for: item)
                }
                .onChange(of: item.id) { _, _ in
                    showAllCommits = false
                    visibleCommits = 10
                }
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
            .tint(.green)
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
            // Green = update available, matching the list rows; "up to date"
            // drops to secondary so the two badges stay distinguishable.
            Text("update → \(latest)").font(.caption.bold()).foregroundStyle(.green)
        case .upToDate:
            Text("up to date").font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Version history (§21)

    private func versionHistorySection(_ item: BrewItem) -> some View {
        GroupBox {
            switch app.versionHistory.status(for: item) {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading version history…").font(.callout).foregroundStyle(.secondary)
                }
            case .loaded(let entries, let origin, let fetchedAt):
                loadedHistory(item, entries: entries, origin: origin, fetchedAt: fetchedAt)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Try again") {
                        Task { await app.versionHistory.load(for: item, taps: model.taps, force: true) }
                    }
                    // Releases fetch independently of the history fetch, so
                    // upstream rows still show when packaging history fails.
                    ForEach(loadedReleases(for: item)) { release in
                        releaseRow(release)
                    }
                }
            }
        } label: {
            HStack {
                Text("Version history")
                Spacer()
                if case .loaded = app.versionHistory.status(for: item) {
                    Button("Reload") {
                        Task { await app.versionHistory.load(for: item, taps: model.taps, force: true) }
                    }
                    .font(.callout)
                }
                if let notes = releaseNotesURL(for: item) {
                    Button("All releases in browser") { NSWorkspace.shared.open(notes) }
                        .font(.callout)
                }
            }
        }
    }

    private func loadedReleases(for item: BrewItem) -> [UpstreamRelease] {
        if case .loaded(let releases) = app.versionHistory.releaseStatus(for: item) { return releases }
        return []
    }

    /// Default view: version bumps plus upstream releases that have no
    /// matching bump yet (10 most recent, newest-first across both sources).
    /// A release whose tag names a bump version merges into that bump's row
    /// (see historyRow); only the leftovers become their own "not packaged"
    /// rows. When the source produced zero recognized bumps (tap-author
    /// subjects are format-free) the full log shows instead of an empty box.
    /// "Show 10 more" pages through the already-fetched list; no refetch.
    private func loadedHistory(_ item: BrewItem, entries: [VersionHistoryEntry],
                               origin: String, fetchedAt: Date) -> some View {
        enum Row: Identifiable {
            case commit(VersionHistoryEntry)
            case release(UpstreamRelease)
            var id: String {
                switch self {
                case .commit(let entry): return "commit:" + entry.id
                case .release(let release): return "release:" + release.id
                }
            }
            var sortDate: Date? {
                switch self {
                case .commit(let entry): return entry.date
                case .release(let release): return release.publishedAt
                }
            }
        }
        let bumps = entries.filter { $0.versionBump != nil }
        let candidates = showAllCommits || bumps.isEmpty ? entries : bumps
        let packaged = bumps.compactMap(\.versionBump)
        let unpackaged = loadedReleases(for: item).filter { release in
            !packaged.contains { upstreamRelease(matching: $0, in: [release]) != nil }
        }
        // Stable newest-first merge: ties keep each source's own order.
        var rows: [Row] = candidates.map(Row.commit)
        rows.append(contentsOf: unpackaged.map(Row.release))
        rows = rows.enumerated().sorted { a, b in
            let da = a.element.sortDate ?? .distantPast
            let db = b.element.sortDate ?? .distantPast
            return da == db ? a.offset < b.offset : da > db
        }.map(\.element)
        let shown = Array(rows.prefix(visibleCommits))
        return VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text("No commits found — \(origin).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { row in
                switch row {
                case .commit(let entry):
                    historyRow(item, entry)
                case .release(let release):
                    releaseRow(release, notPackaged: true)
                }
            }
            if rows.count > visibleCommits {
                Button("Show 10 more") { visibleCommits += 10 }
                    .font(.callout)
            }
            if !showAllCommits, bumps.count < entries.count {
                Toggle("Show all \(entries.count) packaging commits (\(entries.count - bumps.count) hidden)",
                       isOn: $showAllCommits)
                    .font(.caption)
            }
            Text("\(origin) · fetched \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Bump rows are the changelog entry points: the version opens the matching
    /// upstream GitHub release (real change notes, when loaded), falling back
    /// to the packaging commit (core commit page or tap commit via the tap's
    /// git origin); the trailing arrow always goes to the commit. A matched
    /// release merges its title and pre-release flag into the row — this is
    /// where the old "Upstream releases" section's data now lives. The row for
    /// the installed version carries an "installed" chip.
    private func historyRow(_ item: BrewItem, _ entry: VersionHistoryEntry) -> some View {
        let matched: UpstreamRelease? = {
            guard let bump = entry.versionBump else { return nil }
            return upstreamRelease(matching: bump, in: loadedReleases(for: item))
        }()
        let releaseURL = matched?.webURL
        let linkURL = releaseURL ?? entry.webURL
        let isInstalledRow = entry.versionBump.map { item.installedVersions.contains($0) } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let date = entry.date {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("—")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 86, alignment: .trailing)
            if let version = entry.versionBump {
                if let url = linkURL {
                    Button { NSWorkspace.shared.open(url) } label: { Text(version) }
                        .buttonStyle(.plain)
                        .font(.callout.bold())
                        .foregroundStyle(.tint)
                        .help(releaseURL != nil
                              ? "Open \(version) release notes on GitHub"
                              : entry.subject)
                } else {
                    Text(version)
                        .font(.callout.bold())
                        .foregroundStyle(.tint)
                        .help(entry.subject) // full commit subject on hover
                    }
                if isInstalledRow {
                    Text("installed")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15), in: Capsule())
                }
                if matched?.isPrerelease == true {
                    Text("pre-release").font(.caption).foregroundStyle(.orange)
                }
                if let title = matched?.title, title.distinctFrom(version) {
                    Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(entry.subject)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = entry.webURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Open commit on GitHub")
            }
        }
    }

    // MARK: - Upstream release rows (§21, merged into the history list)

    /// A release with no matching packaging bump gets its own row: tag opens
    /// the release page, a "not packaged" chip flags that brew has no bump
    /// for it yet (usually the newest upstream release). Rows in the history
    /// failure fallback omit the chip — packaging state is unknown there.
    private func releaseRow(_ release: UpstreamRelease, notPackaged: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let date = release.publishedAt {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("—")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 86, alignment: .trailing)
            Button {
                if let url = release.webURL { NSWorkspace.shared.open(url) }
            } label: {
                Text(release.tag)
            }
            .buttonStyle(.plain)
            .font(.callout.bold())
            .foregroundStyle(.tint)
            .help("Open \(release.tag) on GitHub")
            if notPackaged {
                Text("not packaged")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help("the upstream released this; no packaging bump found")
            }
            if release.isPrerelease {
                Text("pre-release").font(.caption).foregroundStyle(.orange)
            }
            if let title = release.title, title.distinctFrom(release.tag) {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
    }
}

private extension String {
    /// Release titles that just repeat the version the row already prints
    /// ("0.39.1" beside "v0.39.1") carry no information → drop them. Decode
    /// only catches title == tag; this also catches title == the bump version.
    func distinctFrom(_ version: String) -> Bool {
        func normalize(_ s: String) -> String {
            let lower = s.lowercased()
            return lower.hasPrefix("v") ? String(lower.dropFirst()) : lower
        }
        return normalize(self) != normalize(version)
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
