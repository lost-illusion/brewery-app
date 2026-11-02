import BreweryCore
import Foundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsPane()
            }
            Tab("Changelogs", systemImage: "clock.arrow.circlepath") {
                ChangelogSettingsPane()
            }
            Tab("Updates", systemImage: "bell") {
                UpdatesSettingsPane()
            }
        }
        .frame(width: 460)
    }
}

/// Milestone 1 (design option A): digests while brewery runs. The honest limit is
/// stated here, not buried — app-closed coverage is the launchd milestone.
private struct UpdatesSettingsPane: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppState.notifyKey) private var enabled = false

    var body: some View {
        Form {
            Toggle("Notify when packages have newer versions", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    app.notifications.setEnabled(newValue)
                }
            Text(app.notifications.authorizationSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = app.notifications.statusMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Background agent") {
                Toggle("Check while brewery is closed", isOn: Binding(
                    get: { app.notifications.backgroundAgentRegistered },
                    set: { app.notifications.setBackgroundAgent($0) }))
                Text(app.notifications.backgroundAgentSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Digest checks") {
                Text(statusLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if app.notifications.pendingNewCount > 0 {
                    Text("\(app.notifications.pendingNewCount) new update(s) waiting for the next digest window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Send test notification") { app.notifications.sendTest() }
                    .disabled(!enabled)
            }
            // Form rows truncate single-line text; fixedSize lets the caption
            // wrap instead of ending mid-word at the window edge.
            Text("Checks run while brewery is open — on launch, on window focus, and about once an hour in the background. The background agent above adds checks while the app is closed (hourly on the hour, or on wake if the Mac was asleep then). Background checks run `brew update` first so new tap versions surface; manual refresh (⌘R) does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var statusLine: String {
        var parts: [String] = []
        if let check = app.notifications.lastCheckAt {
            parts.append("Last check: \(check.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("No check yet")
        }
        if let digest = app.notifications.lastDigestAt {
            parts.append("last digest \(digest.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct GeneralSettingsPane: View {
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
    }
}

/// Settings for the future §21 changelog feature + the diagnostics that prove
/// each source actually works on this machine before the feature ships.
private struct ChangelogSettingsPane: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppState.changelogSourceKey) private var source: ChangelogSource = .off
    @AppStorage(AppState.githubTokenKey) private var token = ""
    @AppStorage(AppState.historyRetentionKey) private var retention: HistoryCacheRetention = .thirtyDays

    @State private var sourceOutcome: ProbeOutcome?
    @State private var gitOutcome: ProbeOutcome?
    @State private var testingSource = false
    @State private var testingGit = false
    @State private var cleared = false

    var body: some View {
        Form {
            Picker("Git changelogs", selection: $source) {
                ForEach(ChangelogSource.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: source) { _, newValue in
                if newValue == .off { sourceOutcome = nil }
                app.versionHistory.configure(source: newValue, token: token)
            }

            switch source {
            case .off:
                Text("Version history needs GitHub: brew itself exposes no changelog (§21). Pick a source to enable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .token:
                SecureField("Personal access token", text: $token, prompt: Text("ghp_… / github_pat_…"))
                    .font(.body.monospaced())
                    .onChange(of: token) { _, newToken in
                        sourceOutcome = nil
                        app.versionHistory.configure(source: source, token: newToken)
                    }
                Text("The token is stored in this app's preferences (plain text) and sent only to api.github.com. brew honors the same idea via HOMEBREW_GITHUB_API_TOKEN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ghCLI:
                Text("brewery shells out to `gh api` and reuses its existing sign-in — no token stored here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if source != .off {
                DiagnosticRow(title: "GitHub source",
                              label: source == .token ? "Token test" : "gh test",
                              outcome: sourceOutcome,
                              busy: testingSource,
                              action: { runSourceTest() },
                              explanation: sourceExplanation)
            }

            Section("Local git (tap changelogs)") {
                DiagnosticRow(title: "Local git",
                              label: "git test",
                              outcome: gitOutcome,
                              busy: testingGit,
                              action: { runGitTest() },
                              explanation: "Installed Homebrew taps are git clones; their history needs a working git. The Xcode Command Line Tools provide one.")
            }

            Section("Version history cache") {
                Picker("Keep cached history", selection: $retention) {
                    ForEach(HistoryCacheRetention.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: retention) { _, newValue in
                    app.versionHistory.setRetention(newValue)
                }
                Text("Fetched timelines and release notes are reused until this window expires — cached packages open instantly, across launches. Shortening the window drops entries already outside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Clear cache") {
                        app.versionHistory.clearCache()
                        cleared = true
                    }
                    if cleared {
                        Text("Cache cleared").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .task {
            // Show git state immediately — it's a fact about the machine, not a preference.
            guard gitOutcome == nil else { return }
            runGitTest()
        }
    }

    private var sourceExplanation: String {
        switch source {
        case .token: "Calls api.github.com/user with the token; a 200 proves it is live."
        case .ghCLI: "Runs `gh auth status`; a green run proves gh is installed and signed in."
        case .off: ""
        }
    }

    private func runSourceTest() {
        testingSource = true
        sourceOutcome = nil
        let diagnostics = app.changelogDiagnostics
        Task {
            let outcome: ProbeOutcome
            if source == .token {
                outcome = await diagnostics.probeToken(token)
            } else {
                outcome = await diagnostics.probeGh()
            }
            sourceOutcome = outcome
            testingSource = false
        }
    }

    private func runGitTest() {
        testingGit = true
        gitOutcome = nil
        Task {
            gitOutcome = await app.changelogDiagnostics.probeGit()
            testingGit = false
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let label: String
    let outcome: ProbeOutcome?
    let busy: Bool
    let action: () -> Void
    let explanation: String

    var body: some View {
        GroupBox {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText)
                    .lineLimit(2)
                Spacer()
                Button(busy ? "Testing…" : label, action: action)
                    .disabled(busy)
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Text(title)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if let outcome {
            Image(systemName: outcome.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(outcome.isOK ? Color.green : Color.red)
                .symbolRenderingMode(.palette)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if busy { return "Testing…" }
        guard let outcome else { return "Not tested yet." }
        switch outcome {
        case .ok(let detail): return detail
        case .failed(let message): return message
        }
    }
}
