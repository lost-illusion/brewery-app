import AppKit
import BreweryCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    static let brewSearchPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/usr/bin/brew"]

    let model: InventoryModel
    let jqAvailable: Bool
    let brewFound: Bool

    init(defaults: UserDefaults = .standard) {
        let brewURL = discoverBrew(searchPaths: Self.brewSearchPaths,
                                   pathOverride: defaults.string(forKey: Self.brewOverrideKey))
        brewFound = brewURL != nil
        jqAvailable = Self.detectJq()

        var settings = InventorySettings()
        settings.greedyOutdated = defaults.bool(forKey: Self.greedyKey)

        let storeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brewery", isDirectory: true)
        model = InventoryModel(
            runner: BrewRunner(brewURL: brewURL ?? URL(fileURLWithPath: "/usr/bin/false")),
            manifestFetcher: ManifestFetcher(),
            store: SnapshotStore(directory: storeDir),
            brewProbe: PgrepBrewProbe(),
            jqAvailable: jqAvailable,
            settings: settings)
    }

    static func detectJq() -> Bool {
        ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let greedyKey = "greedyOutdated"
    static let brewOverrideKey = "brewPathOverride"
}

@main
struct BreweryApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .onAppear {
                    // SwiftPM executables can start without frontmost focus.
                    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Inventory") { Task { await app.model.refresh(reason: .manual) } }
                    .keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppState.greedyKey) private var greedy = false
    @AppStorage(AppState.brewOverrideKey) private var brewOverride = ""

    var body: some View {
        @Bindable var model = app.model
        Form {
            Toggle("Greedy outdated (count self-updating casks)", isOn: $model.settings.greedyOutdated)
                .onChange(of: model.settings.greedyOutdated) { _, newValue in
                    greedy = newValue
                    model.settingsChanged()
                }
            GroupBox {
                TextField("Brew path override", text: $brewOverride, prompt: Text("/opt/homebrew/bin/brew"))
                Text("Leave empty to auto-detect. A changed override applies on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: { Text("Brew location") }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct BrewSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppState.brewOverrideKey) private var brewOverride = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("brew not found").font(.title2.bold())
            Text("brewery could not locate a brew executable in /opt/homebrew/bin, /usr/local/bin or /usr/bin.")
            TextField("Brew path override", text: $brewOverride, prompt: Text("/opt/homebrew/bin/brew"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save and relaunch") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
