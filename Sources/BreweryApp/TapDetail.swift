import AppKit
import BreweryCore
import SwiftUI

/// Detail column of the Taps view: where the tap came from, what it offers,
/// and the mutations the GUI offers on it — tap-level (remove, trust) and
/// per-package (trust/untrust the item, install, preview its info).
struct TapDetail: View {
    let tap: TapInfo?
    let model: InventoryModel

    @State private var query = ""
    @State private var confirmRemove = false
    @State private var confirmTrust = false
    @State private var confirmUntrust = false
    /// A not-installed row the user clicked: the pane swaps to its info preview.
    @State private var previewTarget: PreviewTarget?
    /// Bumped after any finished mutation so the shown preview re-fetches —
    /// trust/install change what `brew info` will answer (§22).
    @State private var previewFetch = UUID()
    @State private var previewPhase: PreviewPhase?
    @State private var previewCache: [String: BrewItem] = [:]

    private struct PreviewTarget: Equatable {
        let qualified: String   // tap/name, the form brew accepts
        let name: String        // bare name, for labels
        let kind: BrewItem.Kind
        let installed: Bool     // drives the header chip while the read is in flight
    }
    private enum PreviewPhase { case loading, ready(BrewItem), failed(message: String) }
    private struct PreviewKey: Equatable { let target: PreviewTarget?; let fetch: UUID }

    /// Official taps list brew's whole catalog (8684 formulae here); the pane
    /// caps the rows and points at the filter instead.
    private static let rowCap = 200

    var body: some View {
        if let tap {
            let contents = tapContents(of: tap, inventory: model.items)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(tap)
                    actionBanner
                    if let target = previewTarget {
                        previewPane(tap, target)
                    } else {
                        facts(tap, installedCount: contents.installedCount)
                        contentsBox(tap, contents: contents)
                        actions(tap, installedCount: contents.installedCount)
                    }
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .task(id: PreviewKey(target: previewTarget, fetch: previewFetch)) {
                await performPreviewFetch()
            }
            .onChange(of: model.tapAction) { old, new in
                guard new == .idle, old != .idle else { return }
                previewCache = [:]
                if previewTarget != nil { previewFetch = UUID() }
                // The previewed package just became installed: its row shows it now.
                if case .running(.installing(let qualified)) = old, previewTarget?.qualified == qualified {
                    previewTarget = nil
                }
            }
            .onChange(of: model.upgrade) { old, new in
                // An Update finished: the preview's install facts and outdated
                // badge are stale — refetch from brew.
                guard new == .idle, old != .idle else { return }
                previewCache = [:]
                if previewTarget != nil { previewFetch = UUID() }
            }
            .alert("Remove \(tap.name)?", isPresented: $confirmRemove, presenting: tap) { target in
                if contents.installedCount > 0 {
                    Button("Uninstall \(contents.installedCount), then remove", role: .destructive) {
                        Task { await model.removeTap(target, uninstallingItems: true) }
                    }
                }
                Button("Remove tap only", role: .destructive) {
                    Task { await model.removeTap(target, uninstallingItems: false) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text("""
                    Runs brew untap \(target.name)\(contents.installedCount > 0 ? " — brew refuses to untap a repository that still has packages installed, so “Remove tap only” may fail; the other choice runs brew untap --force, which uninstalls \(contents.installedCount) package(s) first." : ".")
                    """)
            }
            .alert("Trust \(tap.name)?", isPresented: $confirmTrust, presenting: tap) { target in
                Button("Trust tap") { Task { await model.trustTap(target) } }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text("""
                    Runs brew trust --tap \(target.name). Homebrew will then load this tap's formulae, casks and external commands, and code in a tap runs with your user's privileges. Stored in ~/.homebrew/trust.json.
                    """)
            }
            .alert("Stop trusting \(tap.name)?", isPresented: $confirmUntrust, presenting: tap) { target in
                Button("Untrust tap", role: .destructive) { Task { await model.untrustTap(target) } }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text("Runs brew untrust --tap \(target.name). Already-installed packages stay installed; brew stops loading this tap's definitions for new installs and catalog queries.")
            }
        } else {
            ContentUnavailableView("Select a tap", systemImage: "sidebar.right",
                                   description: Text("Pick a tap to see its repository, contents, and trust state."))
        }
    }

    private func header(_ tap: TapInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tap.name).font(.title2.bold())
            HStack(spacing: 6) {
                chip(tap.isExternal ? "external" : "official",
                     tint: tap.isExternal ? .orange : .green)
                chip(tap.installed ? "on disk" : "API mode", tint: .secondary)
                trustChip(tap)
            }
        }
    }

    private func trustChip(_ tap: TapInfo) -> some View {
        switch tap.trusted {
        case .some(true): chip("trusted", tint: .green)
        case .some(false): chip("untrusted", tint: .orange)
        case nil: chip("trust unknown", tint: .secondary)
        }
    }

    private var actionBanner: some View {
        Group {
            switch model.tapAction {
            case .running(let action):
                Label(action.label, systemImage: actionSymbol(action))
                    .font(.callout).foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12))
            case .failed(let action, let message):
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(action.label.dropLast()) failed", systemImage: "exclamationmark.octagon.fill")
                            .font(.callout).foregroundStyle(.red)
                        Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { model.dismissTapAction() }
                }
                .padding(10)
                .background(.red.opacity(0.12))
            case .idle:
                EmptyView()
            }
        }
    }

    private func actionSymbol(_ action: TapAction) -> String {
        switch action {
        case .installing: "arrow.down.app"
        case .trusting, .untrusting, .trustingItem, .untrustingItem: "lock.open"
        default: "arrow.down.app"
        }
    }

    private func facts(_ tap: TapInfo, installedCount: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Repository", tap.remote ?? tap.resolvedRemote ?? "—")
            if tap.customRemote { row("Custom remote", "yes") }
            if tap.isPrivate { row("Private repository", "yes") }
            if let branch = tap.branch { row("Branch", branch) }
            if let head = tap.head { row("HEAD", String(head.prefix(10))) }
            if let lastCommit = tap.lastCommitText { row("Last commit", lastCommit) }
            if let path = tap.onDiskPath { row("On disk", path) }
            row("Available", tap.availableCount == 0
                ? "not reported"
                : "\(tap.formulaNames.count) formulae, \(tap.caskTokens.count) casks")
            if !tap.commandFiles.isEmpty { row("External commands", "\(tap.commandFiles.count)") }
            row("Installed from this tap", "\(installedCount)")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder private func contentsBox(_ tap: TapInfo, contents: TapContents) -> some View {
        let shown = contents.filtered(query.isEmpty ? nil : query)
        if tap.availableCount == 0 {
            Label(model.tapsNamesOnly
                  ? "contents need jq — install jq to list what a tap offers"
                  : "this tap reports no package lists (API mode)",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GroupBox("Available in \(tap.name) (\(shown.count) of \(contents.entries.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Filter this tap", text: $query)
                        .textFieldStyle(.roundedBorder)
                    if tap.isExternal && tap.trusted == false && model.trustStore == nil {
                        Text("per-package trust state unavailable — brew trust could not be read")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if shown.isEmpty {
                        Text("no matches").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(shown.prefix(Self.rowCap)) { entry in
                            entryRow(tap, entry)
                        }
                        if shown.count > Self.rowCap {
                            Text("showing first \(Self.rowCap) of \(shown.count) — filter to narrow it")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    /// Every name opens the same in-pane preview — installed or not — so the
    /// tap pane's click behavior is uniform (§22). Rows also carry the per-item
    /// actions brew offers directly: trust / untrust the definition, install.
    @ViewBuilder private func entryRow(_ tap: TapInfo, _ entry: TapContents.Entry) -> some View {
        let qualified = "\(tap.name)/\(entry.name)"
        let installed = entry.installed != nil
        HStack(spacing: 6) {
            Image(systemName: entry.kind == .formula ? "cube.box" : "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(entry.name) {
                previewTarget = PreviewTarget(qualified: qualified, name: entry.name,
                                              kind: entry.kind, installed: installed)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.tint)
            .help("Preview — brew info --json=v2 \(qualified)")
            Text(installed ? "installed" : "not installed")
                .font(.caption2)
                .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            Spacer()
            trustButton(tap, qualified: qualified, kind: entry.kind, controlSize: .small)
            if entry.installed == nil {
                Button("Install") { Task { await model.installItem(qualified) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("brew install \(qualified) — a fully-qualified install also trusts this item")
            }
        }
        .disabled(model.isMutating)
    }

    /// Per-item trust toggle, shown only where it means something: an external tap
    /// that is not tap-level trusted and whose trust store was read. Trusting the
    /// whole tap already covers its items, so then the toggle would be noise.
    @ViewBuilder private func trustButton(_ tap: TapInfo, qualified: String, kind: BrewItem.Kind,
                                          controlSize: ControlSize = .regular) -> some View {
        if tap.isExternal, tap.trusted != true, let store = model.trustStore {
            let trusted = store.isTrusted(qualified: qualified, kind: kind)
            let flag = kind == .formula ? "--formula" : "--cask"
            Button(trusted ? "Untrust" : "Trust") {
                Task {
                    if trusted { await model.untrustItem(qualified: qualified, kind: kind) }
                    else { await model.trustItem(qualified: qualified, kind: kind) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(controlSize)
            .help(trusted
                  ? "brew untrust \(flag) \(qualified) — brew stops loading this definition"
                  : "brew trust \(flag) \(qualified) — lets brew load just this definition")
        }
    }

    @ViewBuilder private func actions(_ tap: TapInfo, installedCount: Int) -> some View {
        HStack(spacing: 10) {
            if let remote = tap.remote ?? tap.resolvedRemote, let url = URL(string: remote) {
                Button("Open repository") { NSWorkspace.shared.open(url) }
            }
            if tap.isExternal {
                if tap.trusted == false {
                    Button("Trust tap") { confirmTrust = true }
                        .help("brew trust --tap \(tap.name)")
                } else if tap.trusted == true {
                    Button("Untrust tap") { confirmUntrust = true }
                        .help("brew untrust --tap \(tap.name)")
                }
            }
            if tap.installed {
                Button("Remove tap…", role: .destructive) { confirmRemove = true }
                    .help("brew untap \(tap.name)")
            }
        }
        .disabled(model.isMutating)
    }

    // MARK: - Preview of a not-installed entry

    private func performPreviewFetch() async {
        guard let target = previewTarget else { previewPhase = nil; return }
        if let cached = previewCache[target.qualified] { previewPhase = .ready(cached); return }
        previewPhase = .loading
        let result = await model.fetchPreview(qualified: target.qualified, kind: target.kind)
        guard previewTarget == target else { return } // another row was clicked meanwhile
        switch result {
        case .success(let item):
            previewCache[target.qualified] = item
            previewPhase = .ready(item)
        case .failure(let error):
            previewPhase = .failed(message: error.message)
        }
    }

    @ViewBuilder private func previewPane(_ tap: TapInfo, _ target: PreviewTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { previewTarget = nil } label: { Label(tap.name, systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 4) {
                Text(target.qualified).font(.title2.bold())
                HStack(spacing: 6) {
                    chip(target.kind == .formula ? "Formula" : "Cask", tint: .secondary)
                    chip(target.installed ? "installed" : "not installed",
                         tint: target.installed ? .green : .orange)
                    itemTrustChip(tap, qualified: target.qualified, kind: target.kind)
                    if case .ready(let item) = previewPhase { outdatedBadge(item) }
                }
            }
            switch previewPhase {
            case .loading:
                ProgressView("Reading brew info…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    if message.contains("untrusted") {
                        // brew's refusal names the fix; offer it inline, the refetch
                        // fires when the action finishes (onChange resets the fetch id).
                        trustButton(tap, qualified: target.qualified, kind: target.kind)
                    }
                    Button("Retry") { previewFetch = UUID() }
                        .disabled(model.isMutating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
            case .ready(let item):
                previewBody(tap, target, item)
            case nil:
                EmptyView()
            }
        }
    }

    private func previewBody(_ tap: TapInfo, _ target: PreviewTarget, _ item: BrewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = DeprecationNotice(item) {
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(notice.status == .disabled ? Color.red : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background((notice.status == .disabled ? Color.red : Color.orange).opacity(0.12))
                if let command = notice.replacementCommand {
                    Text("Replacement: \(command)").font(.callout)
                }
            }
            if case .failed(let message) = model.upgrade {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.12))
                    .textSelection(.enabled)
            }
            if let desc = item.desc, !desc.isEmpty {
                Text(desc).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let tapName = item.tap { row("Tap", tapName) }
                if !item.installedVersions.isEmpty {
                    row("Installed", item.installedVersions.joined(separator: ", "))
                }
                if let linked = item.linkedVersion { row("Linked keg", linked) }
                if let installedAt = item.installedAt {
                    row("Installed at", installedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let latest = item.latestVersion { row("Latest", latest) }
                if item.kind == .cask, item.autoUpdates { row("Auto-updates", "yes") }
                if item.kind == .formula, item.kegOnly { row("Keg-only", "yes") }
                if !item.dependencies.isEmpty { row("Dependencies", item.dependencies.joined(separator: ", ")) }
            }
            HStack(spacing: 10) {
                if item.installedVersions.isEmpty {
                    Button("Install") { Task { await model.installItem(target.qualified) } }
                        .buttonStyle(.borderedProminent)
                        .help("brew install \(target.qualified) — a fully-qualified install also trusts this item")
                } else {
                    updateButton(item)
                }
                trustButton(tap, qualified: target.qualified, kind: target.kind)
                if let homepage = item.homepage, let url = URL(string: homepage) {
                    Button("Open homepage") { NSWorkspace.shared.open(url) }
                }
            }
            .disabled(model.isMutating)
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

    /// Mirrors the inventory detail page's Update button (same semantics, §70):
    /// only outdated/self-updating previews get it; the model adds --greedy for
    /// self-updating items.
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
                  : "brew update, then brew upgrade \(item.fullName)")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func itemTrustChip(_ tap: TapInfo, qualified: String, kind: BrewItem.Kind) -> some View {
        if tap.isExternal, tap.trusted != true {
            if let store = model.trustStore {
                if store.isTrusted(qualified: qualified, kind: kind) {
                    chip("trusted", tint: .green)
                } else {
                    chip("untrusted", tint: .orange)
                }
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}
