import AppKit
import BreweryCore
import SwiftUI

/// Detail column of the Taps view: where the tap came from, what it offers,
/// and the two mutations the GUI offers on it (remove, trust).
struct TapDetail: View {
    let tap: TapInfo?
    let model: InventoryModel
    let openPackage: (String) -> Void

    @State private var query = ""
    @State private var confirmRemove = false
    @State private var confirmTrust = false
    @State private var confirmUntrust = false

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
                    facts(tap, installedCount: contents.installedCount)
                    contentsBox(tap, contents: contents)
                    actions(tap, installedCount: contents.installedCount)
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
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
                Label(action.label, systemImage: "arrow.down.app")
                    .font(.callout).foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12))
            case .failed(let action, let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(action.label.dropLast()) failed", systemImage: "exclamationmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red)
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
            case .idle:
                EmptyView()
            }
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
                    if shown.isEmpty {
                        Text("no matches").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(shown.prefix(Self.rowCap)) { entry in
                            entryRow(entry)
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

    /// Installed entries link into the inventory; the rest are what the tap
    /// offers but this machine has not installed.
    @ViewBuilder private func entryRow(_ entry: TapContents.Entry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.kind == .formula ? "cube.box" : "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let item = entry.installed {
                Button(entry.name) { openPackage(item.id) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .help("Open \(entry.name)")
                Text("installed").font(.caption2).foregroundStyle(.green)
            } else {
                Text(entry.name).font(.callout)
                Text("not installed").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
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
        .disabled(model.tapAction != .idle)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}
