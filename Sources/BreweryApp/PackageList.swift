import BreweryCore
import SwiftUI

struct PackageList: View {
    let section: BrewSection
    @Binding var kindFilter: KindFilter
    @Binding var query: String
    @Binding var selectedID: String?
    let model: InventoryModel
    let jqAvailable: Bool
    @Binding var history: NavigationHistory
    @State private var confirmUpdateAll = false
    @State private var uninstallTarget: BrewItem?

    private var filtered: [BrewItem] {
        let rows = items(model.items, in: section, query: query.isEmpty ? nil : query,
                         greedy: model.settings.greedyOutdated)
        // The kind segment only governs the Installed pane; other sections
        // already filter by their own rule.
        return section == .all ? items(rows, kind: kindFilter) : rows
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "No matches for “\(query)”" }
        guard section == .all else { return "No packages in this section" }
        switch kindFilter {
        case .all: return "No packages installed"
        case .formulae: return "No formulae installed"
        case .casks: return "No casks installed"
        }
    }

    /// "Update All" acts on everything brew considers outdated, not the
    /// query-filtered view — so the confirmation count must ignore the query.
    private var outdatedTotal: Int {
        items(model.items, in: .outdated, query: nil, greedy: model.settings.greedyOutdated).count
    }

    /// Row-menu confirmation copy: the row shortcut's compact form of the detail
    /// page's uninstallWarning (§26). Dependents cannot be looked up cheaply for
    /// every row's alert copy, so the message points at brew's refusal instead:
    /// a refusal lands in the banner verbatim, and the detail page carries the
    /// full dependents list plus the "Ignore dependents" override.
    private func rowUninstallMessage(_ item: BrewItem) -> String {
        var text = item.kind == .cask
            ? "brew uninstall --cask quits the running app, then removes \(item.name)."
            : "brew uninstall removes the linked version of \(item.name)."
        if item.kind == .formula, item.installedVersions.count > 1 {
            text += " \(item.installedVersions.count) versions are installed — the others stay unless you pick “Remove all”."
        }
        text += " Homebrew then auto-removes formulae that were only installed as dependencies of this one; if other installed packages depend on this one, brew refuses (its message names them — the detail page offers the override)."
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .searchable(text: $query, prompt: "Filter name or description")
        .alert("Update all outdated packages?", isPresented: $confirmUpdateAll, presenting: outdatedTotal) { count in
            Button("Update \(count)") { Task { await model.upgradeAll() } }
            Button("Cancel", role: .cancel) { }
        } message: { count in
            // brew's outdated set can be wider than the GUI one (tap packages
            // show "—" here but brew still upgrades them) — say so before mutating.
            Text("""
                Runs brew update, then brew upgrade. Upgrades everything brew considers outdated (\(count) shown here; tap packages are included even when their version shows as “—”). Pinned packages are skipped; running cask apps may be quit.
                """)
        }
        // Row-menu uninstall confirmation. Fixed title: the presenting item is
        // nil'd on dismiss and an interpolated title would blank mid-animation.
        // The detail page's richer confirmation (dependents lookup, version
        // scope) is a deliberate step up from the row shortcut's one-liner.
        .alert("Uninstall package?", isPresented: Binding(
            get: { uninstallTarget != nil },
            set: { if !$0 { uninstallTarget = nil } }
        ), presenting: uninstallTarget) { item in
            Button("Uninstall", role: .destructive) {
                Task { await model.uninstallItem(qualified: item.fullName, kind: item.kind) }
            }
            if item.kind == .formula, item.installedVersions.count > 1 {
                Button("Remove all \(item.installedVersions.count) versions", role: .destructive) {
                    Task { await model.uninstallItem(qualified: item.fullName, kind: item.kind, allVersions: true) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text(rowUninstallMessage(item))
        }
        .toolbar {
            if section == .all {
                // Replaces the removed column title: principal placement sits
                // exactly where the (sidebar-duplicated) title used to render.
                ToolbarItem(placement: .principal) {
                    Picker("Package kind", selection: $kindFilter) {
                        ForEach(KindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Filter installed packages by kind")
                }
            }
            // Detail-page history sits left of Refresh in the same trailing
            // cluster; write-back to selectedID is no-op in the history
            // (ContentView tracks it via onChange).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let id = history.goBack() { selectedID = id }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to previous package")
                .help("Previous package (⌘[)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let id = history.goForward() { selectedID = id }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .accessibilityLabel("Forward to next package")
                .help("Next package (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                // Manual refresh: re-runs list+info now; the manifest follows its
                // 24 h cache (GUI refresh never runs `brew update` — design §Freshness;
                // the hourly background checks and Update All do).
                // The label lays out in both states (opacity 0, not removed) so the
                // toolbar slot keeps a fixed size while the spinner replaces it.
                Button {
                    Task { await model.refresh(reason: .manual) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .opacity(model.state == .loading ? 0 : 1)
                        .overlay {
                            if model.state == .loading {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
                .disabled(model.state == .loading)
            }
            if section == .outdated {
                ToolbarItem(placement: .primaryAction) {
                    Button { confirmUpdateAll = true } label: {
                        Label("Update All", systemImage: "arrow.down.circle")
                            .opacity(model.upgrade == .idle ? 1 : 0)
                            .overlay {
                                if model.upgrade != .idle {
                                    ProgressView().controlSize(.small)
                                }
                            }
                    }
                    .disabled(model.state == .loading || model.upgrade != .idle || outdatedTotal == 0)
                    .help("brew update, then brew upgrade for everything outdated")
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        switch model.upgrade {
        case .running(let phase):
            Label(phase == .updatingHomebrew ? "Updating Homebrew…" : "Upgrading packages…",
                  systemImage: "arrow.down.circle")
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.12))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
        case .idle:
            EmptyView()
        }
        // Row actions (uninstall, pin) run through model.tapAction; without this
        // banner a row-initiated mutation has no progress and a brew refusal
        // (dependents, pinned) is visible only when that package's detail page is open.
        switch model.tapAction {
        case .running(let action):
            Label(action.label, systemImage: "gear")
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.12))
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
                .textSelection(.enabled)
        case .idle:
            EmptyView()
        }
        if case .failed(let message) = model.state {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
        }
        if !jqAvailable && model.state != .idle {
            Label("jq is missing — plain-text mode; rows are list-only and badges are limited",
                  systemImage: "info.circle")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.12))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            ProgressView("Loading inventory…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.items.isEmpty:
            skeleton
        case .ready, .loading:
            if filtered.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "binoculars")
            } else {
                List(filtered, selection: $selectedID) { item in
                    PackageRow(item: item)
                        // Double-click launches an installed cask's app; single-
                        // click still just selects the row and opens the info
                        // panel. Rows without an app target are inert here.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            if openableCask(item) { openCaskApps(item) }
                        })
                        .contextMenu {
                            if openableCask(item) {
                                Button { openCaskApps(item) } label: {
                                    Label("Open", systemImage: "arrow.up.forward.app")
                                }
                            }
                            // brew pin accepts installed names only (compat §93);
                            // preview rows have nothing to pin. Uninstall goes last:
                            // destructive actions sit at the menu's bottom edge.
                            if !item.installedVersions.isEmpty {
                                Button {
                                    Task {
                                        if item.isPinned {
                                            await model.unpinItem(qualified: item.fullName, kind: item.kind)
                                        } else {
                                            await model.pinItem(qualified: item.fullName, kind: item.kind)
                                        }
                                    }
                                } label: {
                                    Label(item.isPinned ? "Unpin" : "Pin",
                                          systemImage: item.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    uninstallTarget = item
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                                .disabled(item.isPinned)
                                .help(item.isPinned
                                      ? "pinned — brew refuses to uninstall pinned packages; Unpin first"
                                      : "brew uninstall \(item.fullName)")
                            }
                        }
                }
            }
        case .failed:
            ContentUnavailableView("Refresh failed — see the banner above", systemImage: "exclamationmark.octagon")
        }
    }

    private var skeleton: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 4).frame(width: 16, height: 16)
                    VStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).frame(height: 8).foregroundStyle(.tertiary)
                    }
                }
                .redacted(reason: .placeholder)
            }
        }
    }
}

struct PackageRow: View {
    let item: BrewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .formula ? "cube.box" : "shippingbox")
                    .foregroundStyle(.secondary)
                Text(item.name).fontWeight(.medium)
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                if item.isDisabled {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help(DeprecationNotice(item)?.text ?? "disabled")
                } else if item.isDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(DeprecationNotice(item)?.text ?? "deprecated")
                }
                Spacer()
                // Version text never wraps mid-number (a narrow column broke
                // "0.39.1 → 0.40.0" across four lines). The middle bar's own
                // width is pinned in ContentView (navigationSplitViewColumnWidth).
                versionStatus.fixedSize()
            }
            if let desc = item.desc {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if case .listOnly(let reason) = item.sourceState {
                Text(reason).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var versionStatus: some View {
        let installed = item.linkedVersion ?? item.installedVersions.last ?? "?"
        switch item.outdated {
        case .updateAvailable(let latest):
            // Green, not tint: the selected row's background is the tint
            // (blue), so blue-on-blue version text disappears when clicked.
            HStack(spacing: 4) {
                Text(installed).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.green)
                Text(latest).fontWeight(.semibold).foregroundStyle(.green)
            }
        case .upToDate:
            Text(installed).foregroundStyle(.secondary)
        case .selfUpdating:
            HStack(spacing: 4) {
                Text(installed).foregroundStyle(.secondary)
                Text("auto").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        case nil, .some(.unknown):
            Text("—").foregroundStyle(.tertiary)
                .help(listOnlyHelp)
        }
    }

    private var listOnlyHelp: String {
        if case .listOnly(let reason) = item.sourceState { return reason }
        return "no version data for this package"
    }
}
