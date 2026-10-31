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

    var enabled: Bool { defaults.bool(forKey: AppState.notifyKey) }

    private let store: UpdateNotifyStore
    private let defaults: UserDefaults
    private let activity: NSBackgroundActivityScheduler
    private var evaluating = false
    private var isAuthorized = false
    /// Set on enable: the backlog digest fires once authorization is proven, so
    /// pairs are never marked announced while a prompt is still unanswered.
    private var wantsBacklogEvaluate = false
    /// A failed state write pauses announcements: without durable dedup the same
    /// digest would re-ban on every check (design §Notification content & dedup).
    private var writesBroken = false
    private var activityScheduled = false

    init(store: UpdateNotifyStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        activity = NSBackgroundActivityScheduler(identifier: "com.illusion.brewery.update-digest")
        super.init()
        activity.repeats = true
        activity.interval = updateDigestInterval
        activity.tolerance = 3_600
        // The delegate is installed even when disabled: it only routes clicks,
        // and a click that cold-launches the app must reach the routing hook.
        UNUserNotificationCenter.current().delegate = self
        if enabled { startActivity() }
        refreshAuthorizationSummary()
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

    /// Called by the UI after every refresh that produced new inventory.
    func evaluate(items: [BrewItem]) {
        guard enabled, isAuthorized, !evaluating, !writesBroken else { return }
        evaluating = true
        defer { evaluating = false }

        guard let stored = store.load() else {
            statusMessage = "notifications state is unreadable — announcements stay off until it is fixed"
            return
        }
        let current = eligibleUpdateKeys(items: items)
        let outcome = digestDecision(current: current, stored: stored, now: Date())
        if let newState = outcome.newState {
            do {
                try store.save(newState)
            } catch {
                writesBroken = true
                statusMessage = "could not write notifications state — announcements paused"
                return
            }
            lastCheckAt = newState.lastCheckAt
        }
        switch outcome.action {
        case .announce(let text, _):
            pendingNewCount = 0
            post(title: text.title, body: text.body, identifier: digestIdentifier)
            lastDigestAt = Date()
        case .deferredNew:
            pendingNewCount = current.subtracting(stored.announced).count
        case .nothing:
            pendingNewCount = 0
            // Nothing pending: a delivered digest describing a since-resolved
            // backlog is noise sitting in Notification Center (design).
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [digestIdentifier])
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

    // Called only while brewery is frontmost. Digests stay hidden there (the
    // user is already looking at the data — design), but a test notification
    // must always present, or pressing "test" inside the app looks broken.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == testIdentifier ? [.banner] : [])
    }
}
