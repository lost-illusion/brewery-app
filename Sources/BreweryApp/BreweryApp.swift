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
    let changelogDiagnostics: ChangelogDiagnostics
    let versionHistory: VersionHistoryModel
    let notifications: NotificationsCoordinator
    /// Bumped by a notification click; ContentView routes it to the Outdated section.
    var openOutdatedRequested: Date?

    init(defaults: UserDefaults = .standard, headless: Bool = false) {
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
        changelogDiagnostics = ChangelogDiagnostics(exec: ProcessExecRunner(),
                                                    tokenChecker: GitHubAPITokenChecker())

        // Same discovery as the settings diagnostics; a missing binary surfaces
        // as the diagnostic's own fix wording at fetch time.
        let isTool: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        let gitURL = ChangelogDiagnostics.defaultGitSearchPaths.first(where: isTool).map { URL(fileURLWithPath: $0) }
        let ghURL = ChangelogDiagnostics.defaultGhSearchPaths.first(where: isTool).map { URL(fileURLWithPath: $0) }
        var historyAccess = VersionHistoryFetcher.Access()
        historyAccess.source = ChangelogSource(rawValue: defaults.string(forKey: Self.changelogSourceKey) ?? "") ?? .off
        historyAccess.token = defaults.string(forKey: Self.githubTokenKey) ?? ""
        versionHistory = VersionHistoryModel(fetcher: VersionHistoryFetcher(
            access: historyAccess, gitURL: gitURL, ghURL: ghURL,
            exec: ProcessExecRunner(), github: LiveGitHubJSON()),
            store: HistoryCacheStore(directory: storeDir),
            retention: HistoryCacheRetention(rawValue: defaults.string(forKey: Self.historyRetentionKey) ?? "") ?? .thirtyDays)

        notifications = NotificationsCoordinator(store: UpdateNotifyStore(directory: storeDir),
                                                storeDirectory: storeDir, defaults: defaults,
                                                headless: headless)
        notifications.onScheduledTick = { [weak self] in
            guard let self else { return }
            await self.model.refresh(reason: .manual, updateTaps: true)
            self.notifications.evaluate(items: self.model.items)
        }
        notifications.onReadyToEvaluate = { [weak self] in
            guard let self else { return }
            self.notifications.evaluate(items: self.model.items)
        }
        notifications.onOpenOutdated = { [weak self] in self?.openOutdatedRequested = Date() }
    }

    static func detectJq() -> Bool {
        ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let greedyKey = "greedyOutdated"
    static let brewOverrideKey = "brewPathOverride"
    static let changelogSourceKey = "changelogSource"
    static let githubTokenKey = "githubToken"
    static let historyRetentionKey = "historyCacheRetention"
    static let notifyKey = "updateNotificationsEnabled"
}

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
                .task { await AppShot.runIfRequested(app: app) }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Inventory") { Task { await app.model.refresh(reason: .manual) } }
                    .keyboardShortcut("r")
                // Bypasses the 24 h manifest cache and re-downloads version data now.
                Button("Fetch Version Data Now") { Task { await app.model.refresh(reason: .manual, forceManifest: true) } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
        Settings {
            SettingsView()
                .environment(app)
        }
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
