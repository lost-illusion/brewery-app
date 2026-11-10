import BreweryCore
import SwiftUI

/// Middle column of the Taps view: every tap brew knows about, external ones
/// first. The right column (TapDetail) shows a tap's contents and actions.
struct TapsList: View {
    let model: InventoryModel
    let jqAvailable: Bool
    @Binding var selectedTapID: String?

    @State private var query = ""
    @State private var showAddTap = false

    private var visibleTaps: [TapInfo] {
        model.taps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var externalTaps: [TapInfo] { visibleTaps.filter(\.isExternal) }
    private var officialTaps: [TapInfo] { visibleTaps.filter { !$0.isExternal } }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .searchable(text: $query, prompt: "Filter tap name")
        .task { await model.loadTaps() } // lazy: ~2 s and a 340 KB payload, so never part of the inventory refresh
        .sheet(isPresented: $showAddTap) { AddTapSheet(model: model) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddTap = true } label: {
                    Label("Add Tap", systemImage: "plus")
                }
                .disabled(model.state == .loading || model.isMutating)
                .help("brew tap user/repo")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.loadTaps(force: true) }
                } label: {
                    Label("Refresh Taps", systemImage: "arrow.clockwise")
                        .opacity(model.tapsState == .loading ? 0 : 1)
                        .overlay {
                            if model.tapsState == .loading {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
                .disabled(model.tapsState == .loading)
                .help("brew tap-info --installed --json")
            }
        }
    }

    @ViewBuilder private var banners: some View {
        switch model.tapAction {
        case .running(let action):
            Label(action.label, systemImage: "arrow.down.app")
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.12))
        case .failed(_, let message):
            // brew's own refusal (a tap with installed packages, an unknown
            // GitHub repo, …) is shown verbatim rather than paraphrased.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button("Dismiss") { model.dismissTapAction() }
            }
            .padding(10)
            .background(.red.opacity(0.12))
        case .idle:
            EmptyView()
        }
        if case .failed(let message) = model.tapsState {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
        }
        if model.tapsNamesOnly && model.tapsState != .idle {
            Label("jq is missing — taps listed by name only, no contents or git data",
                  systemImage: "info.circle")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.12))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tapsState {
        case .idle:
            ProgressView("Loading taps…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.taps.isEmpty:
            ContentUnavailableView("Loading taps…", systemImage: "arrow.clockwise")
        case .ready, .loading:
            if visibleTaps.isEmpty {
                ContentUnavailableView(query.isEmpty
                    ? "No taps installed — add one to see third-party formulae and casks"
                    : "No taps match “\(query)”",
                    systemImage: "binoculars")
            } else {
                List(selection: $selectedTapID) {
                    if !externalTaps.isEmpty {
                        SwiftUI.Section("External taps (\(externalTaps.count))") {
                            ForEach(externalTaps) { tap in
                                TapRow(tap: tap, installedCount: installedCount(of: tap))
                                    .tag(tap.id)
                            }
                        }
                    }
                    if !officialTaps.isEmpty {
                        SwiftUI.Section("Official taps (\(officialTaps.count))") {
                            ForEach(officialTaps) { tap in
                                TapRow(tap: tap, installedCount: installedCount(of: tap))
                                    .tag(tap.id)
                            }
                        }
                    }
                }
            }
        case .failed:
            ContentUnavailableView("Could not read taps — see the banner above",
                                   systemImage: "exclamationmark.octagon")
        }
    }

    private func installedCount(of tap: TapInfo) -> Int {
        tapContents(of: tap, inventory: model.items).installedCount
    }
}

struct TapRow: View {
    let tap: TapInfo
    let installedCount: Int

    var body: some View {
        // Grid, not HStack (same as PackageRow): the summary and remote lines
        // start exactly at the name's x, so stats scan as a left-aligned
        // column instead of wrapping as a right-edge sawtooth beside the name.
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
            GridRow {
                Image(systemName: tap.isExternal ? "arrow.down.app" : "checkmark.seal")
                    .foregroundStyle(tap.isExternal ? .orange : .secondary)
                    .gridCellAnchor(.top)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tap.name).fontWeight(.medium)
                            .lineLimit(1).truncationMode(.middle)
                        if !tap.installed {
                            Text("API").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .help("not cloned on disk — Homebrew serves it from the API")
                        }
                        if tap.isExternal, tap.trusted == false {
                            Image(systemName: "lock.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("untrusted — brew skips this tap's formulae in catalog queries")
                        }
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit().lineLimit(1)
                    if let remote = tap.remote ?? tap.resolvedRemote {
                        Text(remote).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var summary: String {
        if tap.availableCount == 0 { return installedCount > 0 ? "\(installedCount) installed" : "—" }
        let parts = [
            tap.formulaNames.isEmpty ? nil : "\(tap.formulaNames.count) formulae",
            tap.caskTokens.isEmpty ? nil : "\(tap.caskTokens.count) casks",
        ].compactMap { $0 }
        return "\(parts.joined(separator: " · ")) · \(installedCount) installed"
    }
}
