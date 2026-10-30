import BreweryCore
import SwiftUI

struct PackageList: View {
    let section: BrewSection
    @Binding var query: String
    @Binding var selectedID: String?
    let model: InventoryModel
    let jqAvailable: Bool
    @Binding var history: NavigationHistory
    @State private var confirmUpdateAll = false

    private var filtered: [BrewItem] {
        items(model.items, in: section, query: query.isEmpty ? nil : query,
              greedy: model.settings.greedyOutdated)
    }

    /// "Update All" acts on everything brew considers outdated, not the
    /// query-filtered view — so the confirmation count must ignore the query.
    private var outdatedTotal: Int {
        items(model.items, in: .outdated, query: nil, greedy: model.settings.greedyOutdated).count
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
        .toolbar {
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
                // 24 h cache (refresh never runs `brew update` — design §Freshness;
                // only the Outdated section's Update All does).
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
                ContentUnavailableView(query.isEmpty
                    ? "No packages in this section"
                    : "No matches for “\(query)”",
                    systemImage: "binoculars")
            } else {
                List(filtered, selection: $selectedID) { item in
                    PackageRow(item: item)
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
                versionStatus
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
            HStack(spacing: 4) {
                Text(installed).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.tint)
                Text(latest).fontWeight(.semibold).foregroundStyle(.tint)
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
