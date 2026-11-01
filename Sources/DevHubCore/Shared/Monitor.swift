import Foundation

/// One tab in the popover. The shell only talks to this protocol, so adding a tab means a folder in
/// Core with its `Monitor`, a view, and one line in the app's `MonitorRegistry`.
public protocol Monitor: Sendable {
    var id: String { get }              // "utilities"
    var title: String { get }           // tab label
    func refresh() async throws -> MonitorSnapshot
}

public enum MonitorStatus: Sendable, Codable, Equatable {
    case clean
    case warning(Int)
    case failing(Int)
    case error(String)

    /// `{"state": "failing", "count": 7}`, `{"state": "error", "message": "…"}`.
    private enum CodingKeys: String, CodingKey {
        case state, count, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "warning": self = .warning(try c.decode(Int.self, forKey: .count))
        case "failing": self = .failing(try c.decode(Int.self, forKey: .count))
        case "error": self = .error(try c.decode(String.self, forKey: .message))
        default: self = .clean
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clean:
            try c.encode("clean", forKey: .state)
        case .warning(let count):
            try c.encode("warning", forKey: .state)
            try c.encode(count, forKey: .count)
        case .failing(let count):
            try c.encode("failing", forKey: .state)
            try c.encode(count, forKey: .count)
        case .error(let message):
            try c.encode("error", forKey: .state)
            try c.encode(message, forKey: .message)
        }
    }
}

/// Something a tab flags. Notifications diff these by `id` between refreshes.
public struct MonitorItem: Sendable, Codable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Codable {
        case failing, noData
    }

    /// Stable across refreshes, e.g. `SVC-1|Backup`.
    public let id: String
    public let severity: Severity
    /// `SVC-1 Backup`
    public let title: String
    /// `0 of 5 items`
    public let detail: String
    /// How a banner phrases it after the title, e.g. `is red`, `has overdue items`.
    public let headline: String?

    public init(id: String, severity: Severity, title: String, detail: String, headline: String? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.headline = headline
    }
}

/// A monitor's own data, rendered by its tab view and printed by `--dump`.
public protocol MonitorDetail: Sendable, Encodable {}

public struct MonitorSnapshot: Sendable, Codable {
    public var status: MonitorStatus    // .clean, .warning(count), .failing(count), .error(String)
    public var fetchedAt: Date
    public var summary: String          // menu bar tooltip line, e.g. "Mac 7 red"
    /// What the monitor looked at. Notifications are skipped when it changes.
    public var scope: String
    public var items: [MonitorItem]
    /// Encoded for `--dump`; never decoded, since only the monitor knows its type.
    public var detail: (any MonitorDetail)?

    public init(status: MonitorStatus, fetchedAt: Date, summary: String, scope: String = "",
                items: [MonitorItem] = [], detail: (any MonitorDetail)? = nil) {
        self.status = status
        self.fetchedAt = fetchedAt
        self.summary = summary
        self.scope = scope
        self.items = items
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case status, fetchedAt, summary, scope, items, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(MonitorStatus.self, forKey: .status)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        summary = try c.decode(String.self, forKey: .summary)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        items = try c.decodeIfPresent([MonitorItem].self, forKey: .items) ?? []
        detail = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encode(summary, forKey: .summary)
        try c.encode(scope, forKey: .scope)
        try c.encode(items, forKey: .items)
        if let detail { try c.encode(detail, forKey: .detail) }
    }

    public var failingCount: Int {
        if case .failing(let count) = status { return count }
        return 0
    }
}

/// What the notch alert shows across every tab: red beats orange beats nothing.
public enum HubBadge: Equatable, Sendable {
    case red, orange

    /// `snapshots` are each tab's last successful refresh; `problems` its current error state.
    public static func make(snapshots: [MonitorSnapshot?], problems: [MonitorStatus?]) -> HubBadge? {
        if snapshots.contains(where: { ($0?.failingCount ?? 0) > 0 }) { return .red }
        let failed = problems.contains { status in
            switch status {
            case .error?: return true
            default: return false
            }
        }
        return failed ? .orange : nil
    }
}
