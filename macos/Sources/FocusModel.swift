import AppKit
import Combine

final class FocusModel: ObservableObject {
    @Published var applications: [LiveApplication] = []
    @Published var selection = Set<String>()
    @Published var applicationQuery = ""
    @Published var minutes = 50
    @Published var session: FocusSession?
    @Published var remaining: TimeInterval = 0
    @Published var message: String?
    @Published var completed = false
    let store: SettingsStore
    let enforcer = ApplicationEnforcer()
    var onStatusChange: (() -> Void)?
    var onStart: (() -> Void)?
    var onComplete: (() -> Void)?
    var isPopoverShown: () -> Bool = { false }
    private var settings = FocusSettings()
    private var ticker: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var lastRefresh: TimeInterval = 0
    private var loadingError = false

    init(store: SettingsStore) {
        self.store = store
        do { settings = try store.load() }
        catch { message = error.localizedDescription; loadingError = true }
        minutes = settings.minutes
        selection = Set(settings.applicationSelection.map(\.id))
        if let saved = settings.session {
            remaining = saved.remaining(at: ApplicationService.clock())
            if remaining > 0 { session = saved }
            else { settings.session = nil; try? store.save(settings) }
        }
    }

    var canStart: Bool { !loadingError && !selection.isEmpty && (1...720).contains(minutes) && session == nil }

    var visibleApplications: [LiveApplication] {
        let terms = applicationQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return applications.filter { app in terms.allSatisfy { app.bookmark.appName.localizedStandardContains($0) } }
    }

    var allowedApplications: [LiveApplication] {
        guard let session else { return [] }
        return session.applications.map { bookmark in
            applications.first(where: { $0.id == bookmark.id }) ?? LiveApplication(bookmark: bookmark)
        }
    }

    func launch() {
        enforcer.popoverIsShown = { [weak self] in self?.isPopoverShown() ?? false }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                      NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didWakeNotification,
                      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.refreshApplications()
                self?.tick()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.enforcer.hideShields()
                self?.tick()
            })
        ticker = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
        refreshApplications()
        if let session { enforcer.start(session.applications) }
        tick()
    }

    func refreshApplications() {
        lastRefresh = ApplicationService.clock().continuous
        let saved = session?.applications ?? settings.applicationSelection
        applications = ApplicationService.snapshot(including: saved, excluding: ProcessInfo.processInfo.processIdentifier)
        onStatusChange?()
    }

    func setSelected(_ app: LiveApplication, _ value: Bool) {
        guard session == nil else { return }
        if value { selection.insert(app.id) } else { selection.remove(app.id) }
        saveIdlePreferences()
    }

    func saveIdlePreferences() {
        guard session == nil, !loadingError else { return }
        var next = settings
        if (1...720).contains(minutes) { next.minutes = minutes }
        next.applicationSelection = uniqueApplications((applications.map(\.bookmark) + settings.applicationSelection)
            .filter { selection.contains($0.id) })
        do { try store.save(next); settings = next }
        catch { message = "Не удалось сохранить выбор: \(error.localizedDescription)" }
    }

    func start() {
        guard canStart else { return }
        let chosen = uniqueApplications((applications.map(\.bookmark) + settings.applicationSelection).filter { selection.contains($0.id) })
        do {
            let active = try FocusSession(minutes: minutes, applications: chosen, clock: ApplicationService.clock())
            var next = settings
            next.minutes = minutes
            next.applicationSelection = chosen
            next.session = active
            try store.save(next) // Persist the original deadlines before enabling protection.
            settings = next
            session = active
            remaining = active.duration
            completed = false
            message = nil
            enforcer.start(chosen)
            onStart?()
            tick()
        } catch { message = "Не удалось запустить таймер: \(error.localizedDescription)" }
    }

    func focus(_ app: LiveApplication) {
        guard let session, ApplicationPolicy(applications: session.applications).allows(app.bookmark) else { return }
        if let running = ApplicationService.running(app.bookmark).first {
            ApplicationService.raise(running)
        } else {
            ApplicationService.open(app.bookmark) { [weak self] error in
                if let error { self?.message = "Не удалось открыть приложение: \(error.localizedDescription)" }
                self?.refreshApplications()
                self?.tick()
            }
        }
    }

    func tick() {
        let clock = ApplicationService.clock()
        guard let active = session else {
            if isPopoverShown(), clock.continuous - lastRefresh > 2 { refreshApplications() }
            onStatusChange?()
            return
        }
        let nextRemaining = active.remaining(at: clock)
        if nextRemaining <= 0 { finish(); return }
        if ceil(remaining) != ceil(nextRemaining) { remaining = nextRemaining }
        enforcer.check()
        onStatusChange?()
    }

    private func finish() {
        enforcer.stop()
        session = nil
        remaining = 0
        settings.session = nil
        do { try store.save(settings) }
        catch { message = "Не удалось сохранить завершение: \(error.localizedDescription)" }
        completed = true
        refreshApplications()
        NSSound(named: "Glass")?.play()
        onStatusChange?()
        onComplete?()
    }
}
