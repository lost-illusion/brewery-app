import AppKit
import BreweryCore
import SwiftUI

/// Detail column of the Install pane: the `brew info` preview of a selected
/// not-installed catalog row, with the Install button. Mirrors the Taps pane's
/// preview (TapDetail) minus the trust affordances — core/cask packages need
/// none. Installed selections never reach this view: ContentView routes them
/// to the Installed pane's detail.
struct InstallPreview: View {
    let result: CatalogSearchResult?
    let model: InventoryModel
    /// Clears the list selection (used when an install finishes: the row
    /// re-renders as installed and re-selecting hands off to Installed).
    var clearSelection: () -> Void

    @State private var phase: PreviewPhase?
    @State private var cache: [String: BrewItem] = [:]
    /// Bumped after any finished mutation so the shown preview re-fetches —
    /// an install changes what `brew info` answers (§22), same as TapDetail.
    @State private var previewFetch = UUID()

    private enum PreviewPhase { case loading, ready(BrewItem), failed(message: String) }
    private struct FetchKey: Equatable { let id: String?; let fetch: UUID }

    var body: some View {
        Group {
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(result)
                        facts(result)
                    }
                    .padding(16)
                    .frame(maxWidth: 620, alignment: .leading)
                }
                .task(id: FetchKey(id: result.id, fetch: previewFetch)) {
                    await performPreviewFetch()
                }
                .onChange(of: model.tapAction) { old, new in
                    guard new == .idle, old != .idle else { return }
                    cache = [:]
                    previewFetch = UUID()
                    // The package just became installed: the row shows it now.
                    if case .running(.installing(let qualified)) = old, result.id == qualified {
                        clearSelection()
                    }
                }
            } else {
                ContentUnavailableView("Select a package", systemImage: "sidebar.right",
                                       description: Text("Pick a search result to preview its info and install it."))
            }
        }
        .navigationTitle("")
    }

    private func header(_ result: CatalogSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.kind == .formula ? "cube.box" : "shippingbox")
                    .foregroundStyle(.secondary)
                Text(result.name).font(.title2.bold())
                if let display = result.displayName, display.lowercased() != result.name.lowercased() {
                    Text(display).font(.title2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                chip(result.kind == .formula ? "Formula" : "Cask", tint: .secondary)
                chip("not installed", tint: .orange)
                if showTrustControls(result), let store = model.trustStore {
                    chip(store.isTrusted(qualified: result.id, kind: result.kind) ? "trusted" : "untrusted",
                         tint: store.isTrusted(qualified: result.id, kind: result.kind) ? .green : .orange)
                }
                if case .ready(let item) = phase, let notice = DeprecationNotice(item) {
                    chip(notice.status == .disabled ? "disabled" : "deprecated",
                         tint: notice.status == .disabled ? .red : .orange)
                }
            }
        }
    }

    /// Trust rules follow TapDetail's visibility: only an external tap that is
    /// not tap-level trusted, and only when the trust store or the tap itself
    /// is known — never guess a state.
    private func showTrustControls(_ result: CatalogSearchResult) -> Bool {
        guard let tap = model.taps.first(where: { $0.name.lowercased() == result.tap.lowercased() }),
              tap.isExternal, tap.trusted != true, model.trustStore != nil else { return false }
        return true
    }

    private func trustButton(_ result: CatalogSearchResult, controlSize: ControlSize = .regular) -> some View {
        let store = model.trustStore!
        let trusted = store.isTrusted(qualified: result.id, kind: result.kind)
        let flag = result.kind == .formula ? "--formula" : "--cask"
        return Button(trusted ? "Untrust" : "Trust") {
            Task {
                if trusted { await model.untrustItem(qualified: result.id, kind: result.kind) }
                else { await model.trustItem(qualified: result.id, kind: result.kind) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(controlSize)
        .help(trusted
              ? "brew untrust \(flag) \(result.id) — brew stops loading this definition"
              : "brew trust \(flag) \(result.id) — lets brew load just this definition")
    }

    @ViewBuilder private func facts(_ result: CatalogSearchResult) -> some View {
        switch phase {
        case .loading:
            ProgressView("Reading brew info…")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                // brew's untrusted-tap refusal names the fix; offer it inline —
                // the refetch fires when the trust action finishes (same as TapDetail).
                if message.contains("untrusted"), showTrustControls(result) {
                    trustButton(result)
                }
                Button("Retry") { previewFetch = UUID() }
                    .disabled(model.tapAction != .idle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.12))
        case .ready(let item):
            previewBody(result, item)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func previewBody(_ result: CatalogSearchResult, _ item: BrewItem) -> some View {
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
            if case .failed(_, let message) = model.tapAction {
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
                if let tap = item.tap { factRow("Tap", tap) }
                if let latest = item.latestVersion { factRow("Latest", latest) }
                if item.kind == .cask, item.autoUpdates { factRow("Auto-updates", "yes") }
                if item.kind == .formula, item.kegOnly { factRow("Keg-only", "yes") }
                if !item.dependencies.isEmpty { factRow("Dependencies", item.dependencies.joined(separator: ", ")) }
            }
            HStack(spacing: 10) {
                Button("Install") { Task { await model.installItem(result.id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.tapAction != .idle)
                    .help("brew install -y \(result.id) — the app passes -y; brew's own ask-mode prompt would hang a GUI process (compat §77)\(result.isExternalTap ? " — a fully-qualified install also trusts this item" : "")")
                if showTrustControls(result) {
                    trustButton(result)
                }
                if let homepage = item.homepage, let url = URL(string: homepage) {
                    Button("Open homepage") { NSWorkspace.shared.open(url) }
                }
                if let page = brewPageURL(for: item) {
                    Button("Open on formulae.brew.sh") { NSWorkspace.shared.open(page) }
                }
            }
            .disabled(model.tapAction != .idle)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func performPreviewFetch() async {
        guard let result else { phase = nil; return }
        if let cached = cache[result.id] { phase = .ready(cached); return }
        phase = .loading
        let outcome = await model.fetchPreview(qualified: result.id, kind: result.kind)
        guard self.result?.id == result.id else { return } // another row was selected meanwhile
        switch outcome {
        case .success(let item):
            cache[result.id] = item
            phase = .ready(item)
        case .failure(let error):
            phase = .failed(message: error.message)
        }
    }
}
