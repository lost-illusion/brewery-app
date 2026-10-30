import BreweryCore
import SwiftUI

// SwiftUI also has a `Section`; the inventory one is always BrewSection here.
typealias BrewSection = BreweryCore.Section

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation: BrewSection = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var selectedTapID: String?
    @State private var history = NavigationHistory()
    @State private var showBrewSetup = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $navigation,
                    counts: sidebarCounts(app.model.items, greedy: app.model.settings.greedyOutdated),
                    model: app.model)
        } content: {
            // Sidebar selection stays on BreweryCore.Section: the macOS sidebar
            // List silently drops all row selection for any other tag/binding
            // type — a custom String-raw enum included (verified 2026-10-30 by
            // bisect; compat §7). Taps is therefore a Section case, and
            // PackageList never receives it — the switches route it away.
            switch navigation {
            case .taps:
                TapsList(model: app.model, jqAvailable: app.jqAvailable,
                         selectedTapID: $selectedTapID)
                    .navigationTitle("Taps")
            default:
                PackageList(section: navigation, query: $query, selectedID: $selectedID,
                            model: app.model, jqAvailable: app.jqAvailable,
                            history: $history)
                    .navigationTitle(navigation.title)
            }
        } detail: {
            switch navigation {
            case .taps:
                TapDetail(tap: selectedTapID.flatMap { id in app.model.taps.first { $0.id == id } },
                          model: app.model,
                          openPackage: { id in
                              navigation = .all
                              selectedID = id
                          })
            default:
                PackageDetail(item: selectedID.flatMap { id in app.model.items.first { $0.id == id } },
                              allItems: app.model.items,
                              model: app.model,
                              bottleTag: app.model.manifestBottleTag,
                              openPackage: { id in selectedID = id })
            }
        }
        .onChange(of: selectedID) { _, new in
            // Every selection funnel (list rows, dependency links, back/forward
            // write-backs) lands here; select() no-ops on the current page.
            if let new { history.select(new) }
        }
        .task {
            if app.model.state == .idle { await app.model.refresh(reason: .manual) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.model.refresh(reason: .focus) } }
        }
        .sheet(isPresented: $showBrewSetup) { BrewSetupSheet() }
        .onAppear { if !app.brewFound { showBrewSetup = true } }
    }
}

extension BrewSection {
    var title: String {
        switch self {
        case .all: "All"
        case .formulae: "Formulae"
        case .casks: "Casks"
        case .outdated: "Outdated"
        case .pinned: "Pinned"
        case .deprecated: "Deprecated"
        case .taps: "Taps"
        }
    }

    var icon: String {
        switch self {
        case .all: "list.bullet"
        case .formulae: "cube.box"
        case .casks: "shippingbox"
        case .outdated: "arrow.up.circle"
        case .pinned: "pin"
        case .deprecated: "exclamationmark.triangle"
        case .taps: "arrow.down.app"
        }
    }
}
