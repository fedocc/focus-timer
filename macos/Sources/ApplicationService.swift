import AppKit
import Darwin

struct LiveApplication: Identifiable {
    var bookmark: ApplicationBookmark
    var running: [NSRunningApplication] = []
    var icon: NSImage?
    var id: String { bookmark.id }
    var isRunning: Bool { running.contains { !$0.isTerminated } }
}

// Pure grouping is shared by discovery and tests, including apps with several processes.
func groupApplications(_ bookmarks: [ApplicationBookmark]) -> [ApplicationBookmark] {
    uniqueApplications(bookmarks).sorted {
        let name = $0.appName.localizedStandardCompare($1.appName)
        return name == .orderedSame ? $0.appPath < $1.appPath : name == .orderedAscending
    }
}

enum ApplicationService {
    private static let bootID: String = {
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        if sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 { return String(cString: bytes) }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { return "\(boot.tv_sec):\(boot.tv_usec)" }
        return "unavailable-" + UUID().uuidString
    }()

    static func clock() -> ClockReading {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let continuous = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
        return ClockReading(wall: Date().timeIntervalSince1970, continuous: continuous, bootID: bootID)
    }

    static func bookmark(_ app: NSRunningApplication) -> ApplicationBookmark? {
        guard let url = app.bundleURL, !app.isTerminated else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return ApplicationBookmark(bundleID: app.bundleIdentifier ?? path, appPath: path,
            appName: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
    }

    static func snapshot(including saved: [ApplicationBookmark] = [], excluding ownPID: pid_t) -> [LiveApplication] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID
                && $0.bundleIdentifier != "local.fedor.focus-menu"
        }
        let bookmarks = running.compactMap(bookmark)
        return groupApplications(bookmarks + saved).map { item in
            let processes = running.filter { app in bookmark(app).map(item.matches) ?? false }
            return LiveApplication(bookmark: item, running: processes,
                icon: processes.first?.icon ?? NSWorkspace.shared.icon(forFile: item.appPath))
        }
    }

    static func running(_ bookmark: ApplicationBookmark) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            self.bookmark(app).map(bookmark.matches) ?? false
        }
    }

    static func raise(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.unhide()
        NSApp.yieldActivation(to: app)
        app.activate(options: [])
    }

    static func open(_ bookmark: ApplicationBookmark, completion: @escaping (Error?) -> Void) {
        // Never launch a replacement at an old path under a different bundle identity.
        guard let bundle = Bundle(path: bookmark.appPath),
              (bundle.bundleIdentifier ?? bookmark.appPath) == bookmark.bundleID else {
            completion(FocusError.invalidSession)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bookmark.appPath), configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}

final class FocusShield: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {}
}

final class ApplicationEnforcer {
    private(set) var allowed: [ApplicationBookmark] = []
    private(set) var lastAllowedID: String?
    private(set) var shields: [FocusShield] = []
    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }
    var popoverIsShown: () -> Bool = { false }
    var shieldView: () -> NSView = { NSView() }
    private var lastRedirect: TimeInterval = -.infinity

    func start(_ applications: [ApplicationBookmark]) {
        allowed = uniqueApplications(applications)
        lastAllowedID = nil
        lastRedirect = -.infinity
        // Cover before hiding or activating anything; selection is never inferred from Finder.
        cover()
        let policy = ApplicationPolicy(applications: allowed)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            if let bookmark = ApplicationService.bookmark(app), !policy.allows(bookmark) { app.hide() }
        }
        if let first = allowed.compactMap({ ApplicationService.running($0).first }).first { ApplicationService.raise(first) }
    }

    func stop() {
        hideShields()
        allowed.removeAll()
        lastAllowedID = nil
    }

    func check() {
        guard !allowed.isEmpty else { cover(); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { cover(); return }
        if app.processIdentifier == ownPID {
            if popoverIsShown() { return }
        } else if let bookmark = ApplicationService.bookmark(app), ApplicationPolicy(applications: allowed).allows(bookmark) {
            lastAllowedID = bookmark.id
            hideShields()
            return
        }
        cover()
        let now = ApplicationService.clock().continuous
        guard now - lastRedirect > 0.35 else { return }
        lastRedirect = now
        let ordered = allowed.sorted { $0.id == lastAllowedID && $1.id != lastAllowedID }
        let target = ordered.lazy.compactMap { ApplicationService.running($0).first }.first
        // An unselected app stays unselected even if a permitted app launched it.
        if app.processIdentifier != ownPID { app.hide() }
        if let target { ApplicationService.raise(target) }
    }

    func cover() {
        if shields.count != NSScreen.screens.count {
            hideShields()
            shields = NSScreen.screens.map { screen in
                var frame = screen.frame
                frame.size.height -= max(0, screen.frame.maxY - screen.visibleFrame.maxY)
                let panel = FocusShield(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Фокус"
                panel.level = .screenSaver
                panel.isOpaque = true
                panel.backgroundColor = .windowBackgroundColor
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.canHide = false
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
                panel.contentView = shieldView()
                return panel
            }
        }
        shields.forEach { $0.orderFrontRegardless() }
    }

    func hideShields() {
        shields.forEach { $0.orderOut(nil) }
        shields.removeAll()
    }
}
