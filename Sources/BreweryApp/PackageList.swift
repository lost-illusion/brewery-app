import BreweryCore
import SwiftUI

struct PackageList: View {
    let section: BrewSection
    @Binding var query: String
    @Binding var selectedID: String?
    let model: InventoryModel
    let jqAvailable: Bool

    private var filtered: [BrewItem] {
        items(model.items, in: section, query: query.isEmpty ? nil : query,
              greedy: model.settings.greedyOutdated)
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .searchable(text: $query, prompt: "Filter name or description")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Manual refresh: re-runs list+info now; the manifest follows its
                // 24 h cache (the app never runs `brew update` — design §Freshness).
                if model.state == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.refresh(reason: .manual) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
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
                if item.isDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(item.deprecationReason ?? "deprecated")
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
