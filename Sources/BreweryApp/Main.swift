import AppKit
import BreweryCore
import Foundation

/// The one entry that branches before any UI lifecycle (design §Headless mode):
/// the launchd agent and a manual `--check-updates` run reuse this binary, the
/// bundle identity, and the same notification permissions.
///
/// launchd starts the agent with `XPC_SERVICE_NAME` set to the agent label.
/// Exact match only — a tool-shell may inherit `XPC_SERVICE_NAME=0`, so a
/// presence test is wrong (verified with the gate-3 probe 2026-10-31).
@main
enum BreweryLauncher {
    static func main() {
        let headless = CommandLine.arguments.contains("--check-updates")
            || ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.illusion.brewery.updates"
        if headless {
            HeadlessUpdateCheck.run()
        } else {
            BreweryApp.main()
        }
    }
}

@MainActor
enum HeadlessUpdateCheck {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // windowless, but a real run loop
        let delegate = HeadlessDelegate()
        app.delegate = delegate
        app.run()
        exit(0) // run() returned — delegate already ended the session
    }
}

@MainActor
final class HeadlessDelegate: NSObject, NSApplicationDelegate {
    private var checkTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkTask = Task {
            await runCheck()
            NSApp.terminate(nil)
        }
    }

    private func runCheck() async {
        let storeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brewery", isDirectory: true)
        let logURL = storeDir.appendingPathComponent("headless-check.log")
        func append(_ line: String) {
            let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            if let h = FileHandle(forWritingAtPath: logURL.path) {
                h.seekToEndOfFile(); h.write(Data(entry.utf8)); h.closeFile()
            } else {
                try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
                try? entry.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }

        guard UserDefaults.standard.bool(forKey: AppState.notifyKey) else {
            append("skipped: notifications disabled")
            return
        }
        // No outer lock here on purpose: evaluate() serializes through the
        // coordinator's own UpdateCheckLock, and flock is per-open-file-description —
        // a second fd in the SAME process self-blocks (verified 2026-10-31: an outer
        // headless lock made every inner acquire fail and the digest check no-op).

        let app = AppState(defaults: .standard, headless: true)
        await app.model.refresh(reason: .manual, updateTaps: true)
        // evaluate() refuses while the coordinator's async UN-settings callback has
        // not confirmed authorization — in a short-lived process it can lag the
        // refresh (observed 2026-10-31: silent no-op). Wait, then report honestly.
        var waited = 0.0
        while !app.notifications.isAuthorized && waited < 10 {
            try? await Task.sleep(for: .seconds(0.25))
            waited += 0.25
        }
        let outcome = app.notifications.evaluateReporting(items: app.model.items)
        // Exit-after-async-post is the gate-2 failure mode codex warned about:
        // give the UN delivery callback time to complete before ending the run loop.
        try? await Task.sleep(for: .seconds(3))
        append("check done: inventory \(app.model.state == .ready ? "ok" : "failed"), digest: \(outcome)")
    }
}
