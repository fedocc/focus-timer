import AppKit
import ApplicationServices

// Two disposable GUI apps exercise real activation, windows and system panels.
// Production Focus state and instance.lock are never opened by this harness.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let folder: URL
    let role: String
    var windows: [NSWindow] = []
    var panel: NSSavePanel?
    var timer: Timer?
    var serial = -1
    var phase = "ready"

    init(folder: URL, role: String) { self.folder = folder; self.role = role }
    func applicationDidFinishLaunching(_ notification: Notification) {
        newWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func newWindow() {
        let window = NSWindow(contentRect: NSRect(x: 120 + windows.count * 30, y: 180, width: 420, height: 250),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Focus fixture \(role) — window \(windows.count + 1)"
        window.contentView = NSTextField(labelWithString: "Disposable Focus integration fixture")
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func poll() {
        let commandURL = folder.appendingPathComponent(role + "-command.json")
        if let data = try? Data(contentsOf: commandURL),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let next = command["serial"] as? Int, next != serial {
            serial = next
            switch command["action"] as? String {
            case "window": newWindow(); phase = "window"
            case "open":
                let open = NSOpenPanel()
                open.directoryURL = folder
                panel = open
                phase = "open"
                open.beginSheetModal(for: windows.last!) { _ in }
            case "save":
                let save = NSSavePanel()
                save.directoryURL = folder
                panel = save
                phase = "save"
                save.beginSheetModal(for: windows.last!) { _ in }
            case "dismiss": panel?.cancel(nil); panel = nil; phase = "dismiss"
            case "launch":
                if let path = command["path"] as? String {
                    let config = NSWorkspace.OpenConfiguration()
                    config.arguments = ["--fixture", folder.path, "b"]
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
                }
                phase = "launch"
            default: break
            }
        }
        let status: [String: Any] = ["phase": phase, "serial": serial, "windows": windows.count,
            "panelVisible": panel?.isVisible ?? false, "pid": getpid(), "axTrusted": AXIsProcessTrusted()]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: folder.appendingPathComponent(role + "-state.json"), options: .atomic)
        }
    }
}

struct IntegrationFailure: Error, CustomStringConvertible { var description: String }

@main
enum AppIntegration {
    static func main() throws {
        let args = CommandLine.arguments
        let fixtureRole = Bundle.main.bundleIdentifier?.hasPrefix("local.fedor.focus-fixture.") == true
            ? Bundle.main.bundleIdentifier?.components(separatedBy: ".").last : nil
        if (args.count >= 4 && args[1] == "--fixture") || fixtureRole != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let folder = args.count >= 4 ? URL(fileURLWithPath: args[2])
                : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state")
            let delegate = FixtureDelegate(folder: folder, role: args.count >= 4 ? args[3] : fixtureRole!)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let stateFolder = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        let originalFront = NSWorkspace.shared.frontmostApplication
        let enforcer = ApplicationEnforcer()
        let aURL = root.appendingPathComponent("FixtureA.app")
        let bURL = root.appendingPathComponent("FixtureB.app")
        let idA = "local.fedor.focus-fixture.a", idB = "local.fedor.focus-fixture.b"
        var checks = 0
        var serial = 0
        func pump(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ reason: String, timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { pump(0.05) }
            guard condition() else { throw IntegrationFailure(description: reason) }
            checks += 1
            print("PASS: " + reason)
        }
        func fixture(_ id: String) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }
        }
        func status(_ role: String = "a") -> [String: Any] {
            guard let data = try? Data(contentsOf: stateFolder.appendingPathComponent(role + "-state.json")),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
        func command(_ action: String, path: String? = nil) throws {
            serial += 1
            var value: [String: Any] = ["serial": serial, "action": action]
            value["path"] = path
            try JSONSerialization.data(withJSONObject: value).write(to: stateFolder.appendingPathComponent("a-command.json"), options: .atomic)
            try wait("fixture received \(action)") { status()["serial"] as? Int == serial }
        }
        func launchA() throws {
            try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent("a-command.json"))
            try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent("a-state.json"))
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--fixture", stateFolder.path, "a"]
            var complete = false
            var launchError: Error?
            NSWorkspace.shared.openApplication(at: aURL, configuration: config) { _, error in launchError = error; complete = true }
            try wait("fixture A launched") { complete && fixture(idA) != nil }
            if let launchError { throw launchError }
        }
        defer {
            enforcer.stop()
            fixture(idA)?.terminate()
            fixture(idB)?.terminate()
            let deadline = Date().addingTimeInterval(3)
            while (fixture(idA) != nil || fixture(idB) != nil) && Date() < deadline { pump(0.05) }
            if let originalFront { ApplicationService.raise(originalFront) }
        }
        fixture(idA)?.terminate()
        fixture(idB)?.terminate()
        try wait("previous disposable fixtures exited") { fixture(idA) == nil && fixture(idB) == nil }
        try launchA()
        try wait("fixture has no Accessibility grant") { status()["axTrusted"] as? Bool == false }
        guard let first = fixture(idA), let bookmark = ApplicationService.bookmark(first) else {
            throw IntegrationFailure(description: "missing fixture identity")
        }
        // Preserve availability of every real user app; only disposable B is blocked here.
        let existing = ApplicationService.snapshot(excluding: getpid()).map(\.bookmark).filter { $0.bundleID != idB }
        enforcer.start(uniqueApplications([bookmark] + existing))
        try wait("permitted app becomes frontmost") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idA }
        enforcer.check()
        try wait("permitted app has no shield") { enforcer.shields.isEmpty }
        try command("window")
        enforcer.check()
        try wait("new window in permitted app remains allowed") {
            status()["windows"] as? Int == 2 && enforcer.shields.isEmpty
                && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idA
        }
        for kind in ["open", "save"] {
            try command(kind)
            try wait("native \(kind) panel appears") { status()["panelVisible"] as? Bool == true }
            pump(0.3)
            enforcer.check()
            try wait("native \(kind) panel stays allowed without AX") {
                status()["panelVisible"] as? Bool == true && enforcer.shields.isEmpty
                    && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idA
            }
            try command("dismiss")
        }
        try command("launch", path: bURL.path)
        try wait("separate app B launched by permitted A") { fixture(idB) != nil }
        if let b = fixture(idB) { ApplicationService.raise(b) }
        try wait("unselected B becomes frontmost for enforcement") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idB }
        enforcer.check()
        try wait("unselected B covered immediately") { !enforcer.shields.isEmpty }
        try wait("unselected B redirected to permitted A") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idA }
        enforcer.check()
        try wait("B remains outside the allowed list") {
            guard let b = fixture(idB), let other = ApplicationService.bookmark(b) else { return false }
            return !ApplicationPolicy(applications: enforcer.allowed).allows(other) && enforcer.shields.isEmpty
        }
        let originalPID = first.processIdentifier
        first.terminate()
        try wait("permitted A quits normally") { fixture(idA) == nil }
        try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent("a-command.json"))
        try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent("a-state.json"))
        var reopened = false
        var reopenError: Error?
        ApplicationService.open(bookmark) { error in reopenError = error; reopened = true }
        try wait("closed allowed app reopened through ApplicationService") { reopened && fixture(idA) != nil }
        if let reopenError { throw reopenError }
        try wait("relaunched A has a new PID") { fixture(idA)?.processIdentifier != originalPID }
        if let relaunched = fixture(idA) { ApplicationService.raise(relaunched) }
        try wait("relaunched A becomes frontmost") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == idA }
        enforcer.check()
        try wait("new PID automatically retains application permission") { enforcer.shields.isEmpty && enforcer.lastAllowedID == bookmark.id }
        print("PASS: \(checks) live macOS checks; no protected session was created and no real app was closed")
    }
}
