import AppKit
import BreweryCore
import Foundation
import Observation
import UserNotifications

// File-scope ids: read from nonisolated UN callbacks, which cannot touch the
// MainActor-isolated class's static members.
private let digestIdentifier = "brewery-update-digest"
private let testIdentifier = "brewery-test-notification"

/// Milestone 1 of the notifications design (option A): checks run while the app
/// runs — an NSBackgroundActivityScheduler tick plus every completed inventory
/// refresh feed the same eligibility/dedup logic. Covers app-closed periods only
/// once the launchd agent (milestone 2) exists; the Settings pane says so.
@MainActor
@Observable
final class NotificationsCoordinator: NSObject {
    /// Set by AppState: runs a manual refresh and evaluates the result — the
    /// scheduled-tick body. Kept as a closure so BreweryCore stays notification-free
    /// and the coordinator stays model-free.
    var onScheduledTick: (@MainActor @Sendable () async -> Void)?
    /// Set by AppState: routes a notification click to the Outdated section.
    var onOpenOutdated: (@MainActor @Sendable () -> Void)?
    /// Set by AppState: evaluate the current inventory now (enable-time backlog).
    var onReadyToEvaluate: (@MainActor @Sendable () -> Void)?

    private(set) var authorizationSummary = "not requested yet"
    private(set) var lastDigestAt: Date?
    private(set) var lastCheckAt: Date?
    private(set) var pendingNewCount = 0
    private(set) var statusMessage: String?
    private(set) var backgroundAgentRegistered = false
    private(set) var backgroundAgentSummary = "background agent: not registered"

    var enabled: Bool { defaults.bool(forKey: AppState.notifyKey) }

    private let store: UpdateNotifyStore
    private let storeDirectory: URL
    private let defaults: UserDefaults
    private let activity: NSBackgroundActivityScheduler
    private var evaluating = false
    // Readable module-wide (headless entry polls it before evaluate).
    private(set) var isAuthorized = false
    /// Set on enable: the backlog digest fires once authorization is proven, so
    /// pairs are never marked announced while a prompt is still unanswered.
    private var wantsBacklogEvaluate = false
    /// A failed state write pauses announcements: without durable dedup the same
    /// digest would re-ban on every check (design §Notification content & dedup).
    private var writesBroken = false
    private var activityScheduled = false

    /// `headless` skips the in-process scheduler: the launchd agent is the one
    /// doing the checking there, and a short-lived process must not arm a
    /// repeating activity it will not live to serve.
    init(store: UpdateNotifyStore, storeDirectory: URL, defaults: UserDefaults, headless: Bool = false) {
        self.store = store
        self.storeDirectory = storeDirectory
        self.defaults = defaults
        activity = NSBackgroundActivityScheduler(identifier: "com.illusion.brewery.update-digest")
        super.init()
        activity.repeats = true
        activity.interval = updateDigestInterval
        activity.tolerance = 3_600
        // The delegate is installed even when disabled: it only routes clicks,
        // and a click that cold-launches the app must reach the routing hook.
        UNUserNotificationCenter.current().delegate = self
        // Seed the Settings status line from durable state, or every relaunch
        // reads "No check yet" despite a history of checks.
        if let stored = store.load() {
            lastCheckAt = stored.lastCheckAt
            lastDigestAt = stored.lastDigestAt
        }
        if enabled && !headless { startActivity() }
        refreshAuthorizationSummary()
        refreshBackgroundAgentStatus()
        if !headless { reassertBackgroundAgent() }
    }

    /// A rebuild or app move makes an old plist's Program path stale; re-assert
    /// (rewrite + reload) at GUI launch whenever the consent marker — the plist
    /// file itself — exists. Never from the headless agent.
    private func reassertBackgroundAgent() {
        guard FileManager.default.fileExists(atPath: agentPlistURL.path) else { return }
        writeAgent(on: true)
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: AppState.notifyKey)
        if on {
            wantsBacklogEvaluate = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])
                } catch {
                    self.statusMessage = "authorization failed: \(error.localizedDescription)"
                }
                self.refreshAuthorizationSummary()
                self.startActivity()
            }
        } else {
            wantsBacklogEvaluate = false
            activityScheduled = false
            activity.invalidate()
        }
    }

    // MARK: - Background agent (milestone 2): an app-managed plain LaunchAgent
    //
    // The SMAppService/BundleProgram variant (docs/design gate-3 evidence) worked
    // first and then failed unrepeatably: dyld began SIGKILLing the launchd-spawned
    // binary at exec ("Namespace CODESIGNING, Code 4, Launch Constraint Violation"
    // against the ad-hoc identity) and the submission degraded to `spawn failed`
    // / exit 78 EX_CONFIG while SMAppService status still claimed "registered".
    // A legacy LaunchAgent in ~/Library/LaunchAgents with an absolute Program path
    // was verified working on the same machine (kickstart exit 0) and self-heals
    // across rebuilds: the plist is rewritten with the current executable path and
    // reloaded at GUI launch.

    private static let agentLabel = "com.illusion.brewery.updates"

    private var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
    }

    func setBackgroundAgent(_ on: Bool) { writeAgent(on: on) }

    /// Consent marker: the plist file. On → write current binary's plist, bootout
    /// any stale submission, bootstrap fresh. Off → bootout + delete the file.
    private func writeAgent(on: Bool) {
        if !on {
            runLaunchctl(["bootout", "gui/\(getuid())/\(Self.agentLabel)"])
            try? FileManager.default.removeItem(at: agentPlistURL)
            refreshBackgroundAgentStatus()
            return
        }
        guard let exe = Bundle.main.executablePath else {
            statusMessage = "background agent: could not locate the app executable"
            refreshBackgroundAgentStatus()
            return
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key> <string>\(Self.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exe)</string>
                <string>--check-updates</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>   <integer>10</integer>
                <key>Minute</key> <integer>0</integer>
            </dict>
            <key>ProcessType</key> <string>Background</string>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(at: agentPlistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try plist.write(to: agentPlistURL, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "background agent: could not write the LaunchAgent plist — \(error.localizedDescription)"
            refreshBackgroundAgentStatus()
            return
        }
        runLaunchctl(["bootout", "gui/\(getuid())/\(Self.agentLabel)"]) // idempotent reload
        let (status, output) = runLaunchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
        if status != 0 {
            statusMessage = "background agent: launchctl bootstrap failed (\(status)) — \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        refreshBackgroundAgentStatus()
    }

    private func refreshBackgroundAgentStatus() {
        let (status, _) = runLaunchctl(["print", "gui/\(getuid())/\(Self.agentLabel)"])
        backgroundAgentRegistered = status == 0
        backgroundAgentSummary = status == 0
            ? "background agent: registered — checks daily at 10:00 (or on wake if asleep then), even while brewery is closed"
            : "background agent: not registered"
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "could not run launchctl") }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// This SDK has no suspend/resume: scheduling is the enable switch and
    /// `invalidate()` is the disable switch (repeats reschedules after .finished).
    private func startActivity() {
        guard !activityScheduled else { return }
        activityScheduled = true
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self, self.enabled else { completion(.deferred); return }
                await self.onScheduledTick?()
                completion(.finished)
            }
        }
    }

    /// Headless diagnostic path: same guards as evaluate(), but every refusal
    /// comes back as a string for the log instead of vanishing silently — a
    /// short-lived process must be diagnosable from its log alone (gate 6).
    func evaluateReporting(items: [BrewItem]) -> String {
        if !enabled { return "refused: notifications disabled" }
        if !isAuthorized { return "refused: authorization not confirmed" }
        if evaluating { return "refused: already evaluating" }
        if writesBroken { return "refused: state writes broken" }
        guard let probe = UpdateCheckLock.tryAcquire(directory: storeDirectory) else {
            return "refused: another brewery check holds the lock"
        }
        probe.release() // free for evaluate()'s own acquire immediately after
        return evaluate(items: items) ?? "refused: evaluate guard (state changed mid-check)"
    }

    /// Called by the UI after every refresh that produced new inventory.
    /// Returns a one-line account of what happened (headless log); nil = guard refusal.
    @discardableResult
    func evaluate(items: [BrewItem]) -> String? {
        guard enabled, isAuthorized, !evaluating, !writesBroken else { return nil }
        evaluating = true
        defer { evaluating = false }
        // Serialize with the launchd headless check (design §Scheduling & Homebrew safety).
        guard let lock = UpdateCheckLock.tryAcquire(directory: storeDirectory) else {
            return "refused: another brewery check holds the lock"
        }
        defer { lock.release() }

        guard let stored = store.load() else {
            statusMessage = "notifications state is unreadable — announcements stay off until it is fixed"
            return statusMessage
        }
        let current = eligibleUpdateKeys(items: items)
        let outcome = digestDecision(current: current, stored: stored, now: Date())
        if let newState = outcome.newState {
            do {
                try store.save(newState)
            } catch {
                writesBroken = true
                statusMessage = "could not write notifications state — announcements paused"
                return statusMessage
            }
            lastCheckAt = newState.lastCheckAt
        }
        switch outcome.action {
        case .announce(let text, let total):
            pendingNewCount = 0
            post(title: text.title, body: text.body, identifier: digestIdentifier)
            lastDigestAt = outcome.newState?.lastDigestAt ?? Date()
            return "announced: \(total) eligible"
        case .deferredNew:
            pendingNewCount = current.subtracting(stored.announced).count
            return "deferred: \(pendingNewCount) new within the digest window"
        case .nothing:
            // Already-announced pairs are still outdated: the delivered digest is
            // still accurate and stays in Notification Center.
            pendingNewCount = 0
            return "nothing new: \(current.count) eligible, all already announced"
        case .backlogResolved:
            pendingNewCount = 0
            // Nothing outdated any more: a delivered digest is now stale noise (design).
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [digestIdentifier])
            return "nothing eligible"
        }
    }

    func sendTest() {
        post(title: "brewery test notification",
             body: "Update digests will look like this.",
             identifier: testIdentifier)
    }

    private func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Same-identifier add replaces a still-pending request; delivered ones
        // stay in Notification Center history. No sound (design: ordinary
        // interruption level). Delivery errors surface in the Updates pane —
        // UN fails silently otherwise.
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                guard let error else { return }
                Task { @MainActor in self.statusMessage = "delivery failed: \(error.localizedDescription)" }
            }
    }

    private func refreshAuthorizationSummary() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let summary: String
            switch settings.authorizationStatus {
            case .notDetermined: summary = "permission not requested yet"
            case .denied: summary = "permission denied — allow it in System Settings → Notifications"
            case .authorized: summary = "permission granted"
            case .provisional: summary = "permission provisional — banners go silently to Notification Center"
            @unknown default: summary = "permission status unknown"
            }
            // UNNotificationSettings is not Sendable: read every field here and
            // send only the finished String/Bool across the isolation hop.
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in
                self.authorizationSummary = summary
                self.isAuthorized = authorized
                if authorized, self.wantsBacklogEvaluate {
                    self.wantsBacklogEvaluate = false
                    self.onReadyToEvaluate?()
                }
            }
        }
    }

}

extension NotificationsCoordinator: @MainActor UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onOpenOutdated?()
        }
        completionHandler()
    }

    // Called only while brewery is frontmost — which is exactly when the GUI's
    // launch/focus checks run. Returning [] there dropped the digest entirely
    // (no banner, no Notification Center entry) while its pairs were already
    // persisted as announced, so it could never fire again. Always present.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
