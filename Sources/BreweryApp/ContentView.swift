import BreweryCore
import SwiftUI

// SwiftUI also has a `Section`; the inventory one is always BrewSection here.
typealias BrewSection = BreweryCore.Section

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: BrewSection = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var showBrewSetup = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $section,
                    counts: sidebarCounts(app.model.items, greedy: app.model.settings.greedyOutdated),
                    model: app.model)
        } content: {
            PackageList(section: section, query: $query, selectedID: $selectedID,
                        model: app.model, jqAvailable: app.jqAvailable)
                .navigationTitle(section.title)
        } detail: {
            PackageDetail(item: selectedID.flatMap { id in app.model.items.first { $0.id == id } },
                          bottleTag: app.model.manifestBottleTag)
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
        }
    }
}
