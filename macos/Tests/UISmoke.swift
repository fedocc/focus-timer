import AppKit
import SwiftUI

final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
enum UISmoke {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previewMode = CommandLine.arguments.count < 2 || CommandLine.arguments.contains("--preview")
        let directory = CommandLine.arguments.count < 2
            ? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ui-bundle-preview")
            : URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = FocusModel(store: SettingsStore(url: directory.appendingPathComponent("preview-state.json")))
        let bookmarks = [
            ApplicationBookmark(bundleID: "com.openai.chat", appPath: "/Applications/ChatGPT.app", appName: "ChatGPT"),
            ApplicationBookmark(bundleID: "com.microsoft.VSCode", appPath: "/Applications/Visual Studio Code.app", appName: "Visual Studio Code"),
            ApplicationBookmark(bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app", appName: "Finder"),
            ApplicationBookmark(bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app", appName: "Safari")
        ]
        model.applications = bookmarks.map { item in
            LiveApplication(bookmark: item, running: [NSRunningApplication.current],
                            icon: NSWorkspace.shared.icon(forFile: item.appPath))
        }
        model.selection = Set(model.applications.prefix(2).map(\.id))
        let originalSelection = model.selection
        model.applicationQuery = "VISUAL CODE"
        precondition(model.visibleApplications.count == 1, "search matches multiple terms without case sensitivity")
        model.applicationQuery = "несуществующее приложение"
        precondition(model.visibleApplications.isEmpty && model.selection == originalSelection, "filtering preserves selection")
        model.applicationQuery = ""
        precondition(model.visibleApplications.count == 4 && model.selection == originalSelection, "clearing search restores rows")
        precondition(model.canStart, "starting needs no Accessibility permission")

        func capture(_ name: String, dark: Bool = false) throws {
            let controller = NSHostingController(rootView: FocusMenu(model: model, quit: {}))
            let view = controller.view
            let desired = view.fittingSize
            precondition(desired.width >= 350 && desired.width <= 355, "unexpected menu width")
            precondition(desired.height >= 160 && desired.height < 650, "unexpected menu height")
            let window = PreviewWindow(contentRect: NSRect(origin: .zero, size: desired),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.backgroundColor = .windowBackgroundColor
            window.setContentSize(desired)
            window.orderFrontRegardless()
            window.makeKey()
            app.activate()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            // Capture AppKit too: ImageRenderer omits NSSearchField and native form controls.
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("cannot render") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode") }
            try data.write(to: directory.appendingPathComponent(name + "-view-cache.png"))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0, "native window screenshot failed")
            if previewMode && name == "setup" {
                let finish = directory.appendingPathComponent("finish-preview")
                let deadline = Date().addingTimeInterval(120)
                print("Preview ready")
                while !FileManager.default.fileExists(atPath: finish.path) && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
            }
            window.orderOut(nil)
            print("Rendered \(name): \(Int(desired.width)) × \(Int(desired.height))")
        }

        try capture("setup")
        try capture("setup-dark", dark: true)
        model.applicationQuery = "code"
        try capture("filtered")
        model.applicationQuery = ""
        model.session = try FocusSession(minutes: 50, applications: Array(bookmarks.prefix(2)), clock: ApplicationService.clock())
        model.remaining = 49 * 60 + 42
        let delegate = AppDelegate()
        delegate.model = model
        precondition(delegate.applicationShouldTerminate(app) == .terminateCancel, "normal quit denied during focus")
        let selected = model.selection
        model.setSelected(model.applications[2], true)
        precondition(model.selection == selected, "allowed apps immutable during focus")
        let savedSession = model.session
        model.saveIdlePreferences()
        model.start()
        precondition(model.session == savedSession, "preference save/start cannot reset active deadline")
        try capture("active")
        model.applications = []
        precondition(model.allowedApplications.count == 2, "closed allowed apps remain available to reopen")
        try capture("active-closed")
        model.session = nil
        model.applicationQuery = "missing"
        try capture("empty-search")
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow, "idle quit available")
        print("PASS: native layouts, app search, closed apps, immutable timer/selection, active-session quit denied")
    }
}
