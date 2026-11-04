import AppKit
import BreweryCore
import Foundation
import ScreenCaptureKit

/// README-asset capture knob (development-only; a no-op unless the env var is set).
///
///   BREWERY_APP_SHOT=docs/screenshots/chart.png \
///   BREWERY_APP_SHOT_SECTION=chart \
///   build/Brewery.app/Contents/MacOS/Brewery
///
/// It waits for the inventory to load (a cold refresh runs several `brew`
/// read commands), pins the window to a fixed content size so shots line up,
/// captures its own window with ScreenCaptureKit, and exits. Current-process
/// content discovery needs no screen recording permission and preserves glass.
///
/// BREWERY_APP_SHOT_SECTION accepts the sidebar names (chart, installed,
/// install, outdated, pinned, deprecated, taps) or a Section raw value.
/// BREWERY_APP_SHOT_SIZE (e.g. 1400x820) and BREWERY_APP_SHOT_SETTLE (seconds
/// after the data is ready) override the defaults.
@MainActor
enum AppShot {
    static let pathKey = "BREWERY_APP_SHOT"
    static let sectionKey = "BREWERY_APP_SHOT_SECTION"
    static let sizeKey = "BREWERY_APP_SHOT_SIZE"
    static let settleKey = "BREWERY_APP_SHOT_SETTLE"

    private static let defaultSize = NSSize(width: 1240, height: 780)
    private static let defaultSettle: TimeInterval = 1.5
    private static let loadTimeout: TimeInterval = 120

    static var isRequested: Bool { requested != nil }

    /// Sidebar section to open at launch. Absent or unrecognised → .all, so an
    /// unset env var leaves the app exactly as it was.
    static var initialSection: BrewSection {
        guard let raw = ProcessInfo.processInfo.environment[sectionKey]?
                .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .all }
        switch raw {
        case "chart", "topinstalls": return .topInstalls
        case "installed", "all": return .all
        case "install": return .install
        case "outdated": return .outdated
        case "pinned": return .pinned
        case "deprecated": return .deprecated
        case "taps": return .taps
        default: return BrewSection(rawValue: raw) ?? .all
        }
    }

    private static var requested: (url: URL, size: NSSize, settle: TimeInterval)? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env[pathKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        var size = defaultSize
        if let spec = env[sizeKey], let parsed = parseSize(spec) { size = parsed }
        let settle = env[settleKey].flatMap { Double($0) } ?? defaultSettle
        return (URL(fileURLWithPath: path), size, settle)
    }

    private static func parseSize(_ spec: String) -> NSSize? {
        let parts = spec.lowercased().split(whereSeparator: { $0 == "x" || $0 == "," }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    /// No-op when BREWERY_APP_SHOT is unset. Terminates the app once the PNG is written.
    static func runIfRequested(app: AppState) async {
        guard let shot = requested else { return }
        func log(_ line: String) {
            FileHandle.standardError.write(Data("appshot: \(line)\n".utf8))
        }

        var waited: TimeInterval = 0
        while app.model.state != .ready && waited < loadTimeout {
            try? await Task.sleep(for: .seconds(0.25))
            waited += 0.25
        }
        guard app.model.state == .ready else { log("inventory never reached ready"); exit(1) }

        // These panes load separately from the inventory. Never save a spinner.
        waited = 0
        while waited < loadTimeout {
            let state = switch initialSection {
            case .topInstalls: app.model.topInstallsState
            case .taps: app.model.tapsState
            default: app.model.state
            }
            if state == .ready { break }
            if case .failed(let message) = state { log(message); exit(1) }
            try? await Task.sleep(for: .seconds(0.25))
            waited += 0.25
        }
        guard waited < loadTimeout else { log("section never reached ready"); exit(1) }

        guard let window = targetWindow() else { log("no window to capture"); exit(1) }
        window.setContentSize(shot.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(shot.settle))

        if ProcessInfo.processInfo.environment["BREWERY_APP_SHOT_DUMP"] != nil { dump(view: window.contentView?.superview, log: log, depth: 0) }
        guard await render(window: window, to: shot.url, log: log) else { exit(1) }
        exit(0)
    }

    /// BREWERY_APP_SHOT_DUMP=1: prints the window's AppKit view tree, for
    /// debugging which parts cacheDisplay does and does not paint.
    private static func dump(view: NSView?, log: (String) -> Void, depth: Int) {
        guard let view else { return }
        let indent = String(repeating: "  ", count: depth)
        log("\(indent)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) layer=\(view.layer != nil)")
        if let effect = view as? NSVisualEffectView {
            log("\(indent)  material=\(effect.material) state=\(effect.state)")
        }
        for sub in view.subviews { dump(view: sub, log: log, depth: depth + 1) }
    }

    /// The app's own window, excluding the Settings scene, the agent's
    /// invisible windows, and any sheet still attached.
    private static func targetWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.contentView != nil
                && window.styleMask.contains(.titled) && window.title != "Settings"
        }
    }

    /// Discover only this process's content (macOS 14.4+), rather than using
    /// SCShareableContent.current, which requests access to other apps via TCC.
    /// The desktop-independent filter includes the title bar and composited glass.
    private static func render(window: NSWindow, to url: URL, log: (String) -> Void) async -> Bool {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                log("own window missing from current-process content"); return false
            }
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            let config = SCStreamConfiguration()
            config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
            config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            let capture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: capture)
            guard let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else {
                log("png encoding produced nothing"); return false
            }
            return write(data, to: url, pixels: "\(rep.pixelsWide)x\(rep.pixelsHigh)", log: log)
        } catch {
            log("capture failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func write(_ data: Data, to url: URL, pixels: String, log: (String) -> Void) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            log("write failed: \(error.localizedDescription)"); return false
        }
        log("wrote \(url.path) \(pixels)")
        return true
    }
}
