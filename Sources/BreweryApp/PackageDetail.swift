import AppKit
import BreweryCore
import SwiftUI

struct PackageDetail: View {
    let item: BrewItem?
    let bottleTag: String?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(item)
                    if case .listOnly(let reason) = item.sourceState {
                        Label(reason, systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    facts(item)
                    if !item.dependencies.isEmpty {
                        GroupBox("Dependencies") {
                            Text(item.dependencies.joined(separator: ", "))
                                .textSelection(.enabled)
                        }
                    }
                    if let homepage = item.homepage, let url = URL(string: homepage) {
                        Button("Open homepage") { NSWorkspace.shared.open(url) }
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

    private func header(_ item: BrewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.fullName).font(.title2.bold())
            HStack(spacing: 6) {
                Text(item.kind == .formula ? "Formula" : "Cask").font(.callout)
                outdatedBadge(item)
            }
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
            if item.isDeprecated, let reason = item.deprecationReason { row("Deprecation", reason) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
