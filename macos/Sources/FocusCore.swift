import Foundation

// Decode-only compatibility with the window selection used by versions 1.0–1.1.
struct WindowBookmark: Codable, Equatable {
    var bundleID: String
    var appPath: String
    var appName: String
    var title: String
    var identifier: String?
    var document: String?

    var application: ApplicationBookmark {
        ApplicationBookmark(bundleID: bundleID, appPath: appPath, appName: appName)
    }
}

struct ApplicationBookmark: Codable, Equatable, Identifiable {
    var bundleID: String
    var appPath: String
    var appName: String

    init(bundleID: String, appPath: String, appName: String) {
        self.bundleID = bundleID
        self.appPath = appPath.hasPrefix("/")
            ? URL(fileURLWithPath: appPath).standardizedFileURL.resolvingSymlinksInPath().path : appPath
        self.appName = appName
    }

    private enum CodingKeys: String, CodingKey { case bundleID, appPath, appName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bundleID: try values.decode(String.self, forKey: .bundleID),
                  appPath: try values.decode(String.self, forKey: .appPath),
                  appName: try values.decode(String.self, forKey: .appName))
    }

    // Length-prefixed fields avoid collisions; PID and window metadata never grant access.
    var id: String { "\(bundleID.utf8.count):\(bundleID)\(appPath)" }
    var isValid: Bool { !bundleID.isEmpty && appPath.hasPrefix("/") && !appName.isEmpty }
    func matches(_ other: ApplicationBookmark) -> Bool {
        isValid && other.isValid && bundleID == other.bundleID && appPath == other.appPath
    }
}

func uniqueApplications(_ bookmarks: [ApplicationBookmark]) -> [ApplicationBookmark] {
    var seen = Set<String>()
    return bookmarks.filter { seen.insert($0.id).inserted }
}

struct ApplicationPolicy {
    let applications: [ApplicationBookmark]
    func allows(_ application: ApplicationBookmark) -> Bool {
        applications.contains { $0.matches(application) }
    }
}

struct ClockReading {
    var wall: TimeInterval
    var continuous: TimeInterval
    var bootID: String
}

struct FocusSession: Codable, Equatable {
    var id = UUID()
    var duration: TimeInterval
    var wallDeadline: TimeInterval
    var continuousDeadline: TimeInterval
    var bootID: String
    var applications: [ApplicationBookmark]

    init(minutes: Int, applications: [ApplicationBookmark], clock: ClockReading) throws {
        guard (1...720).contains(minutes), !applications.isEmpty,
              applications.allSatisfy(\.isValid) else { throw FocusError.invalidSession }
        duration = TimeInterval(minutes * 60)
        wallDeadline = clock.wall + duration
        continuousDeadline = clock.continuous + duration
        bootID = clock.bootID
        self.applications = uniqueApplications(applications)
    }

    private enum CodingKeys: String, CodingKey {
        case id, duration, wallDeadline, continuousDeadline, bootID, applications, windows
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        wallDeadline = try values.decode(TimeInterval.self, forKey: .wallDeadline)
        continuousDeadline = try values.decode(TimeInterval.self, forKey: .continuousDeadline)
        bootID = try values.decode(String.self, forKey: .bootID)
        if values.contains(.applications) {
            applications = uniqueApplications(try values.decode([ApplicationBookmark].self, forKey: .applications))
        } else {
            applications = uniqueApplications(try values.decode([WindowBookmark].self, forKey: .windows).map(\.application))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(duration, forKey: .duration)
        try values.encode(wallDeadline, forKey: .wallDeadline)
        try values.encode(continuousDeadline, forKey: .continuousDeadline)
        try values.encode(bootID, forKey: .bootID)
        try values.encode(applications, forKey: .applications)
    }

    func remaining(at clock: ClockReading) -> TimeInterval {
        let value = bootID == clock.bootID
            ? continuousDeadline - clock.continuous
            : wallDeadline - clock.wall
        return max(0, min(duration, value))
    }
}

struct FocusSettings: Codable, Equatable {
    var version = 2
    var minutes = 50
    var applicationSelection: [ApplicationBookmark] = []
    var session: FocusSession?

    init() {}

    private enum CodingKeys: String, CodingKey { case version, minutes, applicationSelection, selection, session }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try values.decode(Int.self, forKey: .version)
        guard savedVersion == 1 || savedVersion == 2 else { throw FocusError.invalidState }
        minutes = try values.decode(Int.self, forKey: .minutes)
        if savedVersion == 1 {
            applicationSelection = uniqueApplications(try values.decode([WindowBookmark].self, forKey: .selection).map(\.application))
        } else {
            applicationSelection = uniqueApplications(try values.decode([ApplicationBookmark].self, forKey: .applicationSelection))
        }
        session = try values.decodeIfPresent(FocusSession.self, forKey: .session)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(minutes, forKey: .minutes)
        try values.encode(applicationSelection, forKey: .applicationSelection)
        try values.encodeIfPresent(session, forKey: .session)
    }
}

enum FocusError: LocalizedError {
    case invalidSession
    case invalidState
    var errorDescription: String? {
        switch self {
        case .invalidSession: return "Выберите хотя бы одно приложение и время от 1 до 720 минут."
        case .invalidState: return "Не удалось прочитать сохраненный таймер. Перезапустите приложение."
        }
    }
}

final class SettingsStore {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> FocusSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return FocusSettings() }
        let data = try Data(contentsOf: url)
        guard data.count < 1_048_576 else { throw FocusError.invalidState }
        let value = try JSONDecoder().decode(FocusSettings.self, from: data)
        guard value.version == 2, (1...720).contains(value.minutes),
              value.applicationSelection.allSatisfy(\.isValid) else { throw FocusError.invalidState }
        if let session = value.session {
            guard session.duration.isFinite, session.duration > 0, session.duration <= 43_200,
                  session.wallDeadline.isFinite, session.continuousDeadline.isFinite,
                  !session.bootID.isEmpty, !session.applications.isEmpty,
                  session.applications.allSatisfy(\.isValid) else { throw FocusError.invalidState }
        }
        return value
    }

    func save(_ value: FocusSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

func countdown(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(ceil(seconds)))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}
