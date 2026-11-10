import BreweryCore
import SwiftUI

/// Content column of the Install pane: search over the core catalog the model
/// already fetched (design 2026-11-02). Selecting a not-installed row shows its
/// info preview in the detail column; selecting an installed row hands off to
/// the Installed pane (Chart precedent, done in ContentView).
struct InstallList: View {
    let results: [CatalogSearchResult]
    @Binding var kindFilter: KindFilter
    @Binding var query: String
    @Binding var selectedID: String?
    let model: InventoryModel

    /// Same cap as the Taps pane's contents box: the catalog is 10k+ rows, the
    /// filter is the narrowing tool, not the list.
    private static let rowCap = 200

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .searchable(text: $query, prompt: "Search formulae and casks")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Package kind", selection: $kindFilter) {
                    ForEach(KindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Filter catalog by kind")
            }
        }
    }

    @ViewBuilder private var banners: some View {
        // Install start/failure stays visible while the user looks at the list,
        // not only in the preview column (same wording as TapDetail's banner).
        switch model.tapAction {
        case .running(let action):
            Label(action.label, systemImage: "arrow.down.app")
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
        if case .failed(let message) = model.state {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
        }
    }

    /// The catalog is the manifest plus installed taps' contents; "nothing to
    /// search" means BOTH sources are empty (a fresh session or a failed refresh).
    private var catalogEmpty: Bool { model.manifest == nil && model.taps.isEmpty }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading where catalogEmpty:
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where catalogEmpty:
            ContentUnavailableView("Catalog unavailable", systemImage: "exclamationmark.octagon",
                                   description: Text("The search catalog comes from the version manifest and your taps — fix the inventory failure and refresh."))
        default:
            if catalogEmpty && model.tapsState == .loading {
                ProgressView("Loading catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalogEmpty {
                ContentUnavailableView("Catalog unavailable", systemImage: "archivebox",
                                       description: Text("Neither the version manifest nor your taps have loaded yet — press Refresh on the Installed pane."))
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search Homebrew", systemImage: "binoculars", description: Text(searchScopeText))
            } else if results.isEmpty {
                ContentUnavailableView("No matches for “\(query)”", systemImage: "binoculars",
                                       description: Text(noMatchText))
            } else {
                list
            }
        }
    }

    private var searchScopeText: String {
        var parts: [String] = []
        if let manifest = model.manifest {
            parts.append("\(manifest.formulae.count) formulae and \(manifest.casks.count) casks")
        }
        let tapCount = model.taps.filter(\.installed).reduce(0) { $0 + $1.availableCount }
        if tapCount > 0 { parts.append("\(tapCount) from your installed taps") }
        return parts.isEmpty ? "Nothing loaded to search yet." : "\(parts.joined(separator: ", ")) are searchable."
    }

    private var noMatchText: String {
        if model.tapsNamesOnly {
            // No jq → `brew tap` gives names only → tap contents never entered the search.
            return "Nothing in core matches. Third-party tap contents need jq — install jq and refresh to search them."
        }
        return "Nothing in core or your installed taps matches this query."
    }

    private var list: some View {
        List(Array(results.prefix(Self.rowCap)), selection: $selectedID) { result in
            CatalogRow(result: result)
        }
        .safeAreaInset(edge: .bottom) {
            if results.count > Self.rowCap {
                Text("showing first \(Self.rowCap) of \(results.count) — narrow the query")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }
}

struct CatalogRow: View {
    let result: CatalogSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: result.kind == .formula ? "cube.box" : "shippingbox")
                    .foregroundStyle(.secondary)
                Text(result.name).fontWeight(.medium)
                if result.installedItemID != nil {
                    Text("installed").font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                if let version = result.latestVersion {
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let subtitle = subtitleText {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Casks have no manifest desc — their product name is the useful subtitle;
    /// tap entries have neither, so their source tap names the row instead.
    private var subtitleText: String? {
        if let desc = result.desc, !desc.isEmpty { return desc }
        if let name = result.displayName, name.lowercased() != result.name.lowercased() { return name }
        if result.isExternalTap { return result.tap }
        return nil
    }
}
