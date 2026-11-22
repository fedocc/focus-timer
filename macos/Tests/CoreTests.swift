import Foundation

@main
enum CoreTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        let first = ApplicationBookmark(bundleID: "com.microsoft.VSCode", appPath: "/Applications/Code.app", appName: "Code")
        let other = ApplicationBookmark(bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app", appName: "Finder")
        let clock = ClockReading(wall: 10_000, continuous: 100, bootID: "boot-a")
        let session = try FocusSession(minutes: 2, applications: [first], clock: clock)
        check(session.remaining(at: clock) == 120, "starts with full duration")
        let halfway = ClockReading(wall: 10_060, continuous: 160, bootID: "boot-a")
        check(session.remaining(at: halfway) == 60, "counts down")
        check(session.remaining(at: ClockReading(wall: 1, continuous: 160, bootID: "boot-a")) == 60, "clock rewind cannot extend timer")
        check(session.remaining(at: ClockReading(wall: 99_999, continuous: 160, bootID: "boot-a")) == 60, "clock forward cannot end timer")
        check(session.remaining(at: ClockReading(wall: 10_120, continuous: 220, bootID: "boot-a")) == 0, "expires at boundary")
        check(session.remaining(at: ClockReading(wall: 10_500, continuous: 600, bootID: "boot-a")) == 0, "sleep/elapsed time expires")
        check(session.remaining(at: ClockReading(wall: 10_060, continuous: 2, bootID: "boot-b")) == 60, "reboot uses original wall deadline")
        check(session.remaining(at: ClockReading(wall: 100, continuous: 2, bootID: "boot-b")) == 120, "reboot recovery capped at original duration")
        let policy = ApplicationPolicy(applications: [first])
        check(policy.allows(first), "selected application is allowed")
        check(!policy.allows(other), "Finder permission cannot grant another program")
        var copy = first
        copy.appPath = "/Applications/Other.app"
        check(!policy.allows(copy), "same bundle ID at another path is not implicitly selected")
        copy = first
        copy.bundleID = "other.application"
        check(!policy.allows(copy), "replacement at same path is denied")
        copy = first
        copy.appName = "Localized name"
        check(policy.allows(copy), "display name never controls access")
        check(uniqueApplications([first, first, other, first]) == [first, other], "one bookmark per application")
        check(countdown(60.1) == "1:01", "fractional seconds round up")
        check(countdown(0) == "0:00", "zero formatting")
        check(countdown(3601) == "1:00:01", "hours formatting")
        for invalid in [0, -1, 721] {
            do { _ = try FocusSession(minutes: invalid, applications: [first], clock: clock); preconditionFailure("invalid duration accepted") }
            catch FocusError.invalidSession { count += 1 }
        }
        do { _ = try FocusSession(minutes: 1, applications: [], clock: clock); preconditionFailure("empty selection accepted") }
        catch FocusError.invalidSession { count += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("focus-menu-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let realApp = folder.appendingPathComponent("Real.app")
        let alias = folder.appendingPathComponent("Alias.app")
        try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realApp)
        let throughAlias = ApplicationBookmark(bundleID: "fixture", appPath: alias.path, appName: "Fixture")
        let throughRealPath = ApplicationBookmark(bundleID: "fixture", appPath: realApp.path, appName: "Fixture")
        check(throughAlias.matches(throughRealPath), "symlink path resolves to the same application")
        check(uniqueApplications([throughAlias, throughRealPath]).count == 1, "canonical paths do not create duplicate rows")
        let store = SettingsStore(url: folder.appendingPathComponent("state.json"))
        let initial = try store.load()
        check(initial == FocusSettings(), "fresh launch defaults")
        var settings = FocusSettings()
        settings.minutes = 2
        settings.applicationSelection = [first]
        settings.session = session
        try store.save(settings)
        let reloaded = try store.load()
        check(reloaded == settings, "timer and application selection persist exactly")
        check(reloaded.session?.remaining(at: halfway) == 60, "relaunch resumes rather than resets timer")

        let legacyWindow: [String: Any] = ["bundleID": first.bundleID, "appPath": first.appPath,
            "appName": first.appName, "title": "one.py", "identifier": "first"]
        var legacySibling = legacyWindow
        legacySibling["title"] = "two.py"
        legacySibling["identifier"] = "second"
        let legacySession: [String: Any] = ["id": session.id.uuidString, "duration": session.duration,
            "wallDeadline": session.wallDeadline, "continuousDeadline": session.continuousDeadline,
            "bootID": session.bootID, "windows": [legacyWindow, legacySibling]]
        let legacy: [String: Any] = ["version": 1, "minutes": 37,
            "selection": [legacyWindow, legacySibling], "session": legacySession]
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        let beforeMigration = try Data(contentsOf: store.url)
        let migrated = try store.load()
        check(migrated.version == 2 && migrated.minutes == 37, "migrate version and retain minutes")
        check(migrated.applicationSelection == [first], "legacy windows merge without duplicate applications")
        check(migrated.session == session, "migration preserves UUID, boot ID, duration and both original deadlines")
        check(migrated.session?.remaining(at: halfway) == 60, "migration cannot reset or extend active timer")
        let afterMigration = try Data(contentsOf: store.url)
        check(afterMigration == beforeMigration, "loading never overwrites original user state")
        try store.save(migrated)
        let migrationReloaded = try store.load()
        check(migrationReloaded == migrated, "migrated session survives v2 save and relaunch")
        let newJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        check(newJSON["selection"] == nil && newJSON["applicationSelection"] != nil, "new state uses application selection only")
        for bad in [Data("broken".utf8), Data("{\"version\":3}".utf8)] {
            try bad.write(to: store.url)
            do { _ = try store.load(); preconditionFailure("invalid state silently reset") }
            catch { count += 1 }
        }
        var invalid = legacy
        var emptySession = legacySession
        emptySession["windows"] = []
        invalid["session"] = emptySession
        try JSONSerialization.data(withJSONObject: invalid).write(to: store.url)
        do { _ = try store.load(); preconditionFailure("empty active session accepted") }
        catch { count += 1 }
        print("PASS: \(count) timer, application policy, persistence and migration checks")
    }
}
