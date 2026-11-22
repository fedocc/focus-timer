import AppKit

@main
enum DiscoveryTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason)
            checks += 1
        }
        let code = ApplicationBookmark(bundleID: "com.microsoft.VSCode", appPath: "/Applications/Code.app", appName: "Code")
        let finder = ApplicationBookmark(bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app", appName: "Finder")
        check(groupApplications([code, code, finder, code]).count == 2, "multiple windows/processes collapse into one app row")
        check(groupApplications([finder, code]) == [code, finder], "list sorted by localized app name")
        check(groupApplications([]).isEmpty, "no phantom apps")
        var copy = code
        copy.appPath = "/Applications/Other Code.app"
        check(groupApplications([code, copy]).count == 2, "different installed copies retain separate policy")
        let snapshot = ApplicationService.snapshot(including: [code, code], excluding: getpid())
        check(snapshot.filter { $0.id == code.id }.count == 1, "closed saved app remains selectable with no duplicate")
        check(Set(snapshot.map(\.id)).count == snapshot.count, "live app discovery has unique rows")
        check(!snapshot.contains { $0.running.contains { $0.processIdentifier == getpid() } }, "own process excluded")
        print("PASS: \(checks) application-discovery checks (NSWorkspace, no Accessibility calls)")
    }
}
