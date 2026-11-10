import BreweryCore
import SwiftUI

// SwiftUI also has a `Section`; the inventory one is always BrewSection here.
typealias BrewSection = BreweryCore.Section

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    // .all unless BREWERY_APP_SHOT_SECTION asks for another pane (AppShot).
    @State private var navigation: BrewSection = AppShot.initialSection
    // Kind segment state lives here (not in PackageList) so it survives sidebar
    // switches; only the Installed pane reads it.
    @State private var kindFilter: KindFilter = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var selectedTapID: String?
    // Install-pane state lives here (not in InstallList) so a sidebar switch
    // doesn't wipe the user's query, kind segment, or selection.
    @State private var installQuery = ""
    @State private var installKind: KindFilter = .all
    @State private var selectedInstallID: String?
    @State private var history = NavigationHistory()
    @State private var showBrewSetup = false
    // Progress sheet (design 2026-11-02 phase 2): presented only when a brew
    // mutation/upgrade is still running after a beat — pin/trust finish in tens
    // of ms and a sheet that blinks is worse than no sheet.
    @State private var showActionProgress = false
    @State private var actionProgressGeneration = 0

    var body: some View {
        // Chart is a two-column layout — sidebar + one full-width card grid,
        // App Store style — while every other section keeps the three-column
        // inventory shape. A NavigationSplitView's column structure is fixed by
        // the initializer overload, so the layout switches by branching on the
        // selection; the earlier columnVisibility-binding trick (.doubleColumn)
        // is not dependable because the toolbar's sidebar toggle drives the
        // same state.
        Group {
            if navigation == .topInstalls {
                NavigationSplitView {
                    sidebar
                } detail: {
                    TopInstallsList(model: app.model, selectedID: $selectedID)
                        .navigationTitle("") // header space blank, like the inventory columns
                }
            } else {
                NavigationSplitView {
                    sidebar
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
                            .navigationTitle("") // header space blank, like the inventory columns
                            .navigationSplitViewColumnWidth(230)
                    case .install:
                        InstallList(results: catalogResults, kindFilter: $installKind,
                                    query: $installQuery, selectedID: $selectedInstallID,
                                    model: app.model)
                            .navigationTitle("")
                            .navigationSplitViewColumnWidth(230)
                    default:
                        // No navigationTitle here: it only repeated the sidebar's
                        // selection. The Installed pane's toolbar carries the kind
                        // segment instead (PackageList, .principal).
                        PackageList(section: navigation, kindFilter: $kindFilter,
                                    query: $query, selectedID: $selectedID,
                                    model: app.model, jqAvailable: app.jqAvailable,
                                    history: $history)
                            .navigationTitle("") // pin it blank; an absent title falls back to the window title
                            // Middle bar pinned at 230 pt (user choice 2026-11-02):
                            // fixed row geometry so versions never wrap mid-number
                            // and names wrap predictably instead of 3+ char fragments.
                            .navigationSplitViewColumnWidth(230)
                    }
                } detail: {
                    switch navigation {
                    case .taps:
                        // Installed tap rows no longer jump to the inventory detail column:
                        // the tap pane's own preview subview serves installed and
                        // not-installed rows identically (same click, same page).
                        TapDetail(tap: selectedTapID.flatMap { id in app.model.taps.first { $0.id == id } },
                                  model: app.model)
                    case .install:
                        // Only not-installed results land here — installed selections
                        // hand off to the Installed pane's detail (onChange below),
                        // same precedent as installed Chart rows.
                        InstallPreview(result: catalogResults.first { $0.id == selectedInstallID },
                                       model: app.model,
                                       clearSelection: { selectedInstallID = nil })
                    default:
                        PackageDetail(item: selectedID.flatMap { id in app.model.items.first { $0.id == id } },
                                      allItems: app.model.items,
                                      model: app.model,
                                      bottleTag: app.model.manifestBottleTag,
                                      openPackage: { id in selectedID = id })
                    }
                }
            }
        }
        .onChange(of: selectedID) { _, new in
            // Every selection funnel (list rows, dependency links, back/forward
            // write-backs) lands here; select() no-ops on the current page.
            if let new {
                // An installed Chart row hands off to the regular inventory view
                // (ids match BrewItem.id): same package, same detail page,
                // three-column layout back. Uninstalled rows stay on the page.
                if navigation == .topInstalls, app.model.items.contains(where: { $0.id == new }) {
                    navigation = .all
                }
                history.select(new)
            }
        }
        .onChange(of: navigation) { _, section in
            // The Install pane's tap half needs tap-info's contents lists; load
            // them lazily on entry (single flight, cached — design 2026-11-02).
            if section == .install { Task { await app.model.loadTaps() } }
            dropStaleSelection()
        }
        .onChange(of: kindFilter) { _, _ in dropStaleSelection() }
        .onChange(of: query) { _, _ in dropStaleSelection() }
        .onChange(of: selectedInstallID) { _, new in
            // An installed search result hands off to the regular inventory view:
            // same package, same detail page, Installed pane selected. The search
            // state (query/kind) survives the switch — only the selection moves.
            guard navigation == .install, let new else { return }
            if let result = catalogResults.first(where: { $0.id == new }),
               let installedID = result.installedItemID {
                selectedInstallID = nil
                navigation = .all
                selectedID = installedID
            }
        }
        .onChange(of: app.model.inventoryUpdated) { _, updated in
            // Every completed inventory refresh — including tap-action and upgrade
            // re-reads inside the model — flows into the digest check. An upgrade
            // can move the selected row out of the pane it was selected in, so
            // the same staleness drop runs here.
            if updated != nil { app.notifications.evaluate(items: app.model.items) }
            dropStaleSelection()
        }
        .onChange(of: app.openOutdatedRequested) { _, requested in
            if requested != nil { navigation = .outdated }
        }
        .task {
            if app.model.state == .idle { await app.model.refresh(reason: .manual) }
            if AppShot.isRequested {
                if navigation == .taps {
                    await app.model.loadTaps()
                    selectedTapID = app.model.taps.first(where: { $0.isExternal })?.id ?? app.model.taps.first?.id
                } else {
                    let rows = items(app.model.items, in: navigation, query: nil,
                                     greedy: app.model.settings.greedyOutdated)
                    selectedID = rows.first(where: { $0.name == "git" })?.id ?? rows.first?.id
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.model.refresh(reason: .focus) } }
        }
        .sheet(isPresented: $showBrewSetup) { BrewSetupSheet() }
        .sheet(isPresented: $showActionProgress) { ActionProgressSheet(model: app.model) }
        .onChange(of: app.model.progressActionLabel) { old, new in
            if new != nil, old == nil {
                actionProgressGeneration += 1
                let generation = actionProgressGeneration
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    // A new action state or an end in the meantime invalidates this open.
                    if generation == actionProgressGeneration, app.model.progressActionLabel != nil {
                        showActionProgress = true
                    }
                }
            } else if new == nil, old != nil {
                actionProgressGeneration += 1 // also invalidates a pending debounce open
                showActionProgress = false
            }
        }
        .onAppear { if !app.brewFound { showBrewSetup = true } }
    }

    /// Local-only catalog search over the manifest + installed taps' contents —
    /// recomputed per render (a few ms over ~14k slim entries).
    private var catalogResults: [CatalogSearchResult] {
        searchCatalog(manifest: app.model.manifest, installed: app.model.items,
                      taps: app.model.taps, query: installQuery, kind: installKind)
    }

    /// Clears a selection the current pane no longer lists. The detail column
    /// resolves selectedID against the whole inventory, so a selection made
    /// under a previous filter/pane kept its page open after the filter moved
    /// on (2026-11-02: sidebar on the empty Outdated pane, right pane still on
    /// the cask selected in Installed). Fresh selections — rows, dependency
    /// links, history write-backs — are untouched here; only filter moves.
    private func dropStaleSelection() {
        // Chart keeps its own grid selection in the same id space; the Install
        // and Taps panes have their own selections. This drop is for the four
        // panes whose list is the filtered inventory.
        switch navigation {
        case .all, .outdated, .pinned, .deprecated: break
        default: return
        }
        if !isVisible(app.model.items, selectedID: selectedID, in: navigation,
                      query: query.isEmpty ? nil : query, kind: kindFilter,
                      greedy: app.model.settings.greedyOutdated) {
            selectedID = nil
        }
    }

    private var sidebar: some View {
        Sidebar(selection: $navigation,
                counts: sidebarCounts(app.model.items, greedy: app.model.settings.greedyOutdated),
                model: app.model)
            .navigationSplitViewColumnWidth(160)
    }
}

extension BrewSection {
    var title: String {
        switch self {
        case .all: "Installed"
        case .install: "Install"
        case .outdated: "Outdated"
        case .pinned: "Pinned"
        case .deprecated: "Deprecated"
        case .taps: "Taps"
        case .topInstalls: "Chart"
        }
    }

    var icon: String {
        switch self {
        case .all: "list.bullet"
        case .install: "plus.magnifyingglass"
        case .outdated: "arrow.up.circle"
        case .pinned: "pin"
        case .deprecated: "exclamationmark.triangle"
        case .taps: "arrow.down.app"
        case .topInstalls: "chart.bar"
        }
    }
}
