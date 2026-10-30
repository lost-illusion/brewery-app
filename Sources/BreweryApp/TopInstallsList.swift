import BreweryCore
import SwiftUI

/// Full-width Brew page: the top 10 formulae and the top 10 casks by install
/// count across Homebrew's official taps (analytics API only — compat §24),
/// laid out App Store style as two columns — formulae left, casks right —
/// with a 30/90/365-day switcher.
/// Rows are ecosystem data, not inventory: a card can name a package this
/// machine has never installed. An installed card carries a green badge, its
/// name jumps to the All section with that package selected (ids match
/// BrewItem.id), and its "Get" button (which opens the package page on
/// formulae.brew.sh) is disabled.
struct TopInstallsList: View {
    let model: InventoryModel
    @Binding var selectedID: String?

    @State private var period: AnalyticsPeriod = .d30

    var body: some View {
        VStack(spacing: 0) {
            banners
            header
            content
        }
        .task { await model.loadTopInstalls(period: period) }
        .onChange(of: period) { _, new in
            Task { await model.loadTopInstalls(period: new) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.loadTopInstalls(period: period, force: true) }
                } label: {
                    Label("Refresh Installs", systemImage: "arrow.clockwise")
                        .opacity(model.topInstallsState == .loading ? 0 : 1)
                        .overlay {
                            if model.topInstallsState == .loading {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
                .disabled(model.topInstallsState == .loading)
                .help("Re-download the install analytics for the selected window")
            }
        }
    }

    private var headline: String {
        switch period {
        case .d30: "Popular this month"
        case .d90: "Popular this quarter"
        case .d365: "Popular this year"
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(headline)
                .font(.title2.bold())
            Spacer()
            // The period switcher (top right): 30/90/365-day analytics windows.
            Picker("Window", selection: $period) {
                ForEach(AnalyticsPeriod.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var banners: some View {
        if case .failed(let message) = model.topInstallsState {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.12))
        }
    }

    @ViewBuilder private var content: some View {
        if let result = model.topInstalls[period] {
            // A failed re-fetch keeps the last good columns visible under the banner.
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    cardColumn("Formulae", result.formulae)
                    cardColumn("Casks", result.casks)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        } else {
            switch model.topInstallsState {
            case .idle, .loading:
                ProgressView("Loading Homebrew install analytics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView("Analytics fetch failed — see the banner above",
                                       systemImage: "exclamationmark.octagon")
            case .ready:
                EmptyView() // unreachable: ready always carries a result
            }
        }
    }

    private func cardColumn(_ title: String, _ rows: [TopInstall]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                TopInstallCard(rank: index + 1, item: row, period: period,
                               installed: model.items.contains { $0.id == row.id },
                               openInInventory: { selectedID = row.id })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct TopInstallCard: View {
    let rank: Int
    let item: TopInstall
    let period: AnalyticsPeriod
    let installed: Bool
    let openInInventory: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            // The rank tile stands in for the app-icon artwork Homebrew doesn't have.
            Text("#\(rank)")
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Installed cards are the jump affordance; uninstalled names
                    // are plain text (no inventory page exists for them).
                    if installed {
                        Button(action: openInInventory) {
                            Text(item.name).font(.headline)
                        }
                        .buttonStyle(.plain)
                        .help("Open in inventory")
                        Text("installed").font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else {
                        Text(item.name).font(.headline)
                    }
                }
                if let desc = item.desc {
                    Text(desc).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                // The App Store "Get": opens the package page on formulae.brew.sh.
                // Installed cards get a plain gray disabled Get instead (installing
                // itself stays a confirmed brew action elsewhere; the name jumps to
                // the inventory). The column header already names the kind.
                if installed {
                    // Disabled, and gray (not a faded-blue prominent): the bordered
                    // style under a secondary tint stays readable as "nothing to get".
                    Button(action: {}) {
                        Text("Get").frame(minWidth: 56)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help("Already installed — click the name to open it in the inventory")
                } else {
                    Button {
                        openURL(item.pageURL)
                    } label: {
                        Text("Get").frame(minWidth: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open on formulae.brew.sh")
                }
                // Download count as its own block under the button.
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.installs, format: .number)
                        .font(.body.weight(.semibold).monospacedDigit())
                    Text("installs · \(period.label) days")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
