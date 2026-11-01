import Foundation

/// What the last refresh of each tab flagged, persisted so banners don't repeat across restarts.
/// Holds item IDs, titles, severities and sent reminder keys; never secrets.
public struct LastSeen: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var severity: MonitorItem.Severity
        public var title: String
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var scope: String
        public var items: [String: Item]
    }

    public var tabs: [String: Tab]
    public var sentKeys: [String]

    public static let maxSentKeys = 40

    public init(tabs: [String: Tab] = [:], sentKeys: [String] = []) {
        self.tabs = tabs
        self.sentKeys = sentKeys
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevHub/last-seen.json")
    }

    public static func load(from url: URL = defaultURL) -> LastSeen? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LastSeen.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func hasSent(_ key: String) -> Bool { sentKeys.contains(key) }

    public mutating func markSent(_ key: String) {
        guard !hasSent(key) else { return }
        sentKeys.append(key)
        if sentKeys.count > Self.maxSentKeys { sentKeys.removeFirst(sentKeys.count - Self.maxSentKeys) }
    }
}

public enum HubEvent: Equatable, Sendable {
    /// Newly flagged, or flagged with another severity (no data turning red).
    case flagged(MonitorItem)
    case recovered(id: String, title: String)
}

public enum SnapshotDiff {
    /// No banners for a tab's first refresh ever, or after its scope changed.
    public static func events(previous: LastSeen.Tab?, current: MonitorSnapshot) -> [HubEvent] {
        guard let previous, previous.scope == current.scope else { return [] }
        let currentIDs = Set(current.items.map(\.id))
        let flagged = current.items
            .filter { previous.items[$0.id]?.severity != $0.severity }
            .map(HubEvent.flagged)
        let recovered = previous.items
            .filter { !currentIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { HubEvent.recovered(id: $0.key, title: $0.value.title) }
        return flagged + recovered
    }

    public static func record(_ snapshot: MonitorSnapshot) -> LastSeen.Tab {
        LastSeen.Tab(
            scope: snapshot.scope,
            items: Dictionary(snapshot.items.map { ($0.id, LastSeen.Item(severity: $0.severity, title: $0.title)) },
                              uniquingKeysWith: { first, _ in first })
        )
    }
}

/// Once-a-day banners, keyed so each is sent at most once.
public enum HubReminders {
    public static func dayKey(_ now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func morningKey(_ now: Date, calendar: Calendar = .current) -> String {
        "morning-\(dayKey(now, calendar: calendar))"
    }

    /// How long after the chosen time a missed summary (Mac asleep, app not running) is still sent.
    public static let morningWindowMinutes = 180

    /// A working day, from the chosen time (minutes after midnight) until the window closes.
    public static func isMorningDue(now: Date, minuteOfDay: Int, calendar: Calendar = .current) -> Bool {
        guard WorkingDays.isWorkingDay(now, calendar: calendar) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minute >= minuteOfDay && minute < minuteOfDay + morningWindowMinutes
    }
}

/// Banner text, kept here so it's unit-tested.
public enum HubSummary {
    public struct Banner: Equatable, Sendable {
        public let id: String
        public let title: String
        public let body: String
    }

    /// Up to `individualLimit` banners one by one; beyond that one banner each for flagged and recovered.
    public static let individualLimit = 3

    public static func banners(_ events: [HubEvent], tabID: String, tabTitle: String) -> [Banner] {
        let flagged = events.compactMap { event -> MonitorItem? in
            if case .flagged(let item) = event { return item }
            return nil
        }
        let recovered = events.compactMap { event -> (id: String, title: String)? in
            if case .recovered(let id, let title) = event { return (id, title) }
            return nil
        }
        var banners: [Banner] = []

        if flagged.count <= individualLimit {
            banners += flagged.map { item in
                Banner(
                    id: "\(tabID)-flagged-\(item.id)",
                    title: "\(tabTitle): \(item.title) \(item.headline ?? (item.severity == .failing ? "is red" : "has no data"))",
                    body: item.severity == .failing ? item.detail : "No value in the latest report refresh."
                )
            }
        } else {
            banners.append(Banner(id: "\(tabID)-flagged", title: "\(tabTitle): \(flagged.count) newly flagged",
                                  body: list(flagged.map(\.title))))
        }

        if recovered.count <= individualLimit {
            banners += recovered.map {
                Banner(id: "\(tabID)-recovered-\($0.id)", title: "\(tabTitle): \($0.title) recovered", body: "No longer flagged in the latest refresh.")
            }
        } else {
            banners.append(Banner(id: "\(tabID)-recovered", title: "\(tabTitle): \(recovered.count) recovered",
                                  body: list(recovered.map(\.title))))
        }
        return banners
    }

    /// `SVC-1 Backup, SVC-2 Vulnerability, SVC-3 OS Logging, SVC-4 PAM, …`
    static func list(_ titles: [String]) -> String {
        titles.prefix(4).joined(separator: ", ") + (titles.count > 4 ? ", …" : "")
    }

    /// One line per tab: its summary, or why it has none.
    public static func morning(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
